module sparkles.core_cli.process_utils;

import core.time : Duration, msecs;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.core_cli.text.readers :
    readInteger, readUntil, skipSpaces, tryConsume;

void enforceExitStatus(int status, string command)
{
    import std.format : format;
    import std.exception : enforce;
    enforce(status == 0,
        "Command `%s` failed with exit code %s.".format(command, status)
    );
}

string executeShell(in string command)
{
    import std.process : executeShell;
    const result = command.executeShell;
    enforceExitStatus(result.status, command);
    return result.output;
}

// ---------------------------------------------------------------------------
// Resource-monitored execution
// ---------------------------------------------------------------------------

/**
Peak resource use of a spawned process and its descendants, sampled while it
runs. `peakRssBytes` is the largest summed resident-set size observed across
the whole process tree (a `dub` build, say, plus the `ldc2` child it spawns —
which is usually where the memory lives). `cpuTime` is a best-effort estimate
(the largest tree-summed user+system CPU seen at a sample; a child's CPU is
lost from the sum once it exits, so treat it as a lower bound).

`sampled` is `false` on platforms without `/proc` (currently every non-Linux
target): there $(LREF executeMonitored) still runs the process and returns its
output, but collects no resource figures.
*/
struct ResourceUsage
{
    size_t peakRssBytes;   /// max summed RSS over the process tree
    Duration cpuTime;      /// best-effort summed user+system CPU (lower bound)
    size_t sampleCount;    /// number of samples taken
    bool sampled;          /// false when no sampler is available (non-Linux)
}

/// The outcome of $(LREF executeMonitored): the child's exit status, its
/// combined stdout+stderr (matching `std.process.execute`'s contract), and the
/// $(LREF ResourceUsage) gathered while it ran.
struct MonitoredResult
{
    int status;
    string output;
    ResourceUsage usage;
}

/**
Runs `args` to completion like `std.process.execute` — returning the exit
status and the combined stdout+stderr — but spawns it non-blocking and samples
the resident-set size and CPU of the whole process tree every `sampleInterval`
while it runs, so a memory blow-up can be attributed to a specific process.

`onSample`, if given, is invoked after each sample with the running
$(LREF ResourceUsage) (its `peakRssBytes` updated, `cpuTime` carrying the
latest tree total), letting the caller log a live trace. Sampling is
Linux-only (it reads `/proc`); elsewhere the process still runs and its output
is returned, but `usage.sampled` is `false` and no figures are collected.

Output is redirected to a temp file (not a pipe) so a chatty child cannot
deadlock against an undrained pipe while we sample.
*/
MonitoredResult executeMonitored(
    const(string)[] args,
    Duration sampleInterval = 250.msecs,
    scope void delegate(in ResourceUsage sample) @safe onSample = null,
)
{
    import std.process : spawnProcess, tryWait, wait;
    import std.stdio : File, stdin;
    import std.file : tempDir, readText, remove;
    import std.path : buildPath;
    import std.conv : text;
    import std.process : thisProcessID;
    import core.atomic : atomicOp;
    import core.thread : Thread;

    static shared size_t counter;
    const id = atomicOp!"+="(counter, 1);
    const logPath = buildPath(tempDir,
        text("sparkles-mon-", thisProcessID, "-", id, ".log"));

    MonitoredResult result;

    auto sink = File(logPath, "w");
    auto pid = spawnProcess(args, stdin, sink, sink);

    version (linux)
        result.usage.sampled = true;

    for (;;)
    {
        const w = tryWait(pid);

        version (linux)
        {
            const rss = treeRssBytes(pid.processID);
            if (rss > result.usage.peakRssBytes)
                result.usage.peakRssBytes = rss;
            const cpu = treeCpuTime(pid.processID);
            if (cpu > result.usage.cpuTime)
                result.usage.cpuTime = cpu;
            result.usage.sampleCount++;
            if (onSample !is null)
                onSample(result.usage);
        }

        if (w.terminated)
        {
            result.status = w.status;
            break;
        }
        Thread.sleep(sampleInterval);
    }

    sink.close();
    result.output = readText(logPath);
    try
        remove(logPath);
    catch (Exception)
    {
    }                                    // best-effort cleanup
    return result;
}

/// Current resident-set size of this process in bytes (`0` off Linux).
version (linux)
size_t selfRssBytes() @trusted
{
    import std.file : readText;

    try
    {
        const kb = parseVmRssKbFromStatus(readText("/proc/self/status"));
        return kb.hasValue ? kb.value * 1024 : 0;
    }
    catch (Exception)
        return 0;
}
else
size_t selfRssBytes() @safe => 0;

// ---------------------------------------------------------------------------
// /proc parsers
// ---------------------------------------------------------------------------
//
// These are pure, `@nogc` slice walkers built on `core_cli.text.readers`: the
// `/proc` files arrive as already-read `const(char)[]`, and a malformed line is
// surfaced as a `ParseExpected` error rather than a silent sentinel. The
// readers that fetch the files (below) allocate and so cannot be `@nogc`.

/// The slice after the last `)` in `s` (`null` if there is none). The `comm`
/// field of a `/proc/<pid>/stat` line is parenthesised and may itself contain
/// spaces and parens, so the fixed numeric fields begin only after the *last*
/// `)`.
private const(char)[] afterLastParen(return scope const(char)[] s)
    @safe pure nothrow @nogc
{
    ptrdiff_t close = -1;
    foreach (i, c; s)
        if (c == ')')
            close = i;
    return close < 0 ? null : s[close + 1 .. $];
}

/**
Parses the parent PID from a `/proc/<pid>/stat` line. After the last `)` the
tokens are `state ppid pgrp …`, so `ppid` is the second. Fails (with an
`unexpectedEnd`/`unexpectedCharacter` $(REF ParseError,
sparkles,core_cli,text,errors)) when there is no `)` or the `ppid` field is
missing or non-numeric.
*/
ParseExpected!int parsePpidFromStat(const(char)[] stat) @safe pure nothrow @nogc
{
    auto cur = afterLastParen(stat);
    if (cur.length == 0)
        return parseErr!int(ParseErrorCode.unexpectedEnd, 0);

    skipSpaces(cur);
    readUntil(cur, " ");        // skip the `state` token
    skipSpaces(cur);

    auto ppid = readInteger!uint(cur);
    if (!ppid.hasValue)
        return parseErr!int(ppid.error);
    return parseOk(cast(int) ppid.value);
}

/// `utime`/`stime` clock-tick pair from a `/proc/<pid>/stat` line.
struct CpuTicks
{
    ulong utime;
    ulong stime;
    ulong total() const @safe pure nothrow @nogc => utime + stime;
}

/**
Parses `(utime, stime)` clock ticks from a `/proc/<pid>/stat` line. After the
last `)` they are the 12th and 13th tokens (the 11 before them — `state ppid
pgrp session tty tpgid flags minflt cminflt majflt cmajflt` — are skipped).
Fails when the line is truncated before those fields.
*/
ParseExpected!CpuTicks parseCpuTicksFromStat(const(char)[] stat)
    @safe pure nothrow @nogc
{
    auto cur = afterLastParen(stat);
    if (cur.length == 0)
        return parseErr!CpuTicks(ParseErrorCode.unexpectedEnd, 0);

    skipSpaces(cur);
    foreach (_; 0 .. 11)        // skip state … cmajflt
    {
        readUntil(cur, " ");
        skipSpaces(cur);
    }

    auto utime = readInteger!ulong(cur);
    if (!utime.hasValue)
        return parseErr!CpuTicks(utime.error);
    skipSpaces(cur);
    auto stime = readInteger!ulong(cur);
    if (!stime.hasValue)
        return parseErr!CpuTicks(stime.error);

    return parseOk(CpuTicks(utime.value, stime.value));
}

/**
Parses the `VmRSS:` value (kilobytes) from a `/proc/<pid>/status` file. The
line reads `VmRSS:\t   12345 kB`. Fails (`unexpectedEnd`) when no `VmRSS:` line
is present.
*/
ParseExpected!size_t parseVmRssKbFromStatus(const(char)[] status)
    @safe pure nothrow @nogc
{
    enum label = "VmRSS:";

    auto cur = status;
    while (cur.length)
    {
        auto line = readUntil(cur, "\n");
        tryConsume(cur, '\n');
        if (line.length < label.length || line[0 .. label.length] != label)
            continue;

        auto value = line[label.length .. $];
        skipSpaces(value);      // skip the leading tab/spaces before the digits
        return readInteger!size_t(value);
    }
    return parseErr!size_t(ParseErrorCode.unexpectedEnd, 0);
}

// ---------------------------------------------------------------------------
// /proc tree readers (Linux only)
// ---------------------------------------------------------------------------

version (linux)
{
    /// PIDs of `rootPid` and every transitive descendant, found by walking the
    /// `ppid` links in `/proc/[0-9]*/stat`. Best-effort: a process that exits
    /// mid-scan is simply skipped.
    private int[] collectTreePids(int rootPid) @trusted
    {
        import std.file : dirEntries, SpanMode, readText;
        import std.path : baseName;

        int[int] ppidOf;
        try
        {
            foreach (de; dirEntries("/proc", SpanMode.shallow))
            {
                const(char)[] name = de.name.baseName;
                auto pidR = readInteger!uint(name);
                if (!pidR.hasValue || name.length != 0)
                    continue;               // skip non-numeric /proc entries
                const pid = cast(int) pidR.value;
                string stat;
                try
                    stat = readText("/proc/" ~ de.name.baseName ~ "/stat");
                catch (Exception)
                    continue;               // vanished between listing and read
                const ppid = parsePpidFromStat(stat);
                if (ppid.hasValue)
                    ppidOf[pid] = ppid.value;
            }
        }
        catch (Exception)
        {
        }

        int[][int] children;
        foreach (pid, pp; ppidOf)
            children[pp] ~= pid;

        int[] tree = [rootPid];
        bool[int] seen = [rootPid: true];
        for (size_t i = 0; i < tree.length; i++)
            if (auto kids = tree[i] in children)
                foreach (k; *kids)
                    if (k !in seen)
                    {
                        seen[k] = true;
                        tree ~= k;
                    }
        return tree;
    }

    /// Summed resident-set size (bytes) of `rootPid`'s process tree.
    private size_t treeRssBytes(int rootPid) @trusted
    {
        import std.file : readText;
        import std.conv : text;

        size_t total;
        foreach (pid; collectTreePids(rootPid))
        {
            try
            {
                const kb = parseVmRssKbFromStatus(
                    readText(text("/proc/", pid, "/status")));
                if (kb.hasValue)
                    total += kb.value * 1024;
            }
            catch (Exception)
            {
            }
        }
        return total;
    }

    /// Summed user+system CPU of `rootPid`'s process tree.
    private Duration treeCpuTime(int rootPid) @trusted
    {
        import std.file : readText;
        import std.conv : text;
        import core.sys.posix.unistd : sysconf, _SC_CLK_TCK;

        const clk = sysconf(_SC_CLK_TCK);
        if (clk <= 0)
            return Duration.zero;

        ulong ticks;
        foreach (pid; collectTreePids(rootPid))
        {
            try
            {
                const c = parseCpuTicksFromStat(
                    readText(text("/proc/", pid, "/stat")));
                if (c.hasValue)
                    ticks += c.value.total;
            }
            catch (Exception)
            {
            }
        }
        return msecs(cast(long)(ticks * 1000 / clk));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("process_utils.parsePpidFromStat.handlesCommWithSpacesAndParens")
@safe pure nothrow @nogc
unittest
{
    // comm = "(ldc2 stage)" — embedded space and parens; ppid is 4242.
    const a = parsePpidFromStat("1234 ((ldc2 stage)) R 4242 1234 1234 0 -1 4194560 100 0");
    assert(a.hasValue && a.value == 4242);

    // Simple comm.
    const b = parsePpidFromStat("17 (dub) S 9 17 17 0");
    assert(b.hasValue && b.value == 9);

    // Malformed (no `)`) → error, not a sentinel value.
    assert(!parsePpidFromStat("garbage").hasValue);
}

@("process_utils.parseCpuTicksFromStat.readsUtimeStime")
@safe pure nothrow @nogc
unittest
{
    // After the last ')': state ppid pgrp session tty tpgid flags
    //   minflt cminflt majflt cmajflt utime stime …
    //   (indices 0..)         7      8       9      10     11    12
    const c = parseCpuTicksFromStat("5 (prog) R 1 5 5 0 -1 0 10 0 20 0 314 159 0 0");
    assert(c.hasValue);
    assert(c.value.utime == 314);
    assert(c.value.stime == 159);
    assert(c.value.total == 473);

    assert(!parseCpuTicksFromStat("nope").hasValue);
}

@("process_utils.parseVmRssKbFromStatus.findsRss")
@safe pure nothrow @nogc
unittest
{
    const status =
        "Name:\tldc2\nVmPeak:\t  900000 kB\nVmRSS:\t  842156 kB\nThreads:\t8\n";
    const rss = parseVmRssKbFromStatus(status);
    assert(rss.hasValue && rss.value == 842_156);

    // Absent → error.
    assert(!parseVmRssKbFromStatus("Name:\tx\nThreads:\t1\n").hasValue);
}
