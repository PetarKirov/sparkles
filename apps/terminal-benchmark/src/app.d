/// Repeatable CPU benchmark harness for the sparkles terminal emulator.
///
/// The terminal redraws the whole grid every frame, so the metric that matters
/// is CPU consumed at a fixed rendering load. This harness launches one or more
/// terminal binaries against deterministic, self-generated escape-sequence
/// workloads, samples each process's own CPU ticks from `/proc/<pid>/stat` over
/// a fixed window, and prints a comparison table.
///
/// Two scenarios capture the two regimes found while profiling:
///
///   - `idle`   — paint a dense full screen once, then hold. With dirty-frame
///                skipping this should fall to near zero; without it the
///                terminal keeps redrawing a static screen at the frame cap.
///   - `render` — paint a dense full screen, then force a redraw every frame
///                (via SPARKLES_BENCH_FORCE_REDRAW) without feeding new parse
///                work. This isolates the *render* path — the metric the cell
///                renderer moves. (A stream workload is parse-bound instead.)
///   - `churn`  — repaint the entire grid as fast as the terminal will accept.
///                Dominated by VT parsing, not rendering; kept as a whole-stack
///                throughput check.
///
/// It needs a real display (raylib opens a GL window); it is a local/interactive
/// tool, not a headless CI check. vtebench/termbench (packaged in the flake) are
/// available in the dev shell for manual throughput runs; this harness focuses
/// on the render-CPU delta, which is what the renderer work moves.
module app;

import std.stdio;
import std.process;
import std.file; // write/readText/mkdirRecurse/rmdirRecurse/tempDir/FileException
import std.path : baseName, buildPath;
import std.format : format;
import std.array : appender;
import std.algorithm : min, max;
import core.thread : Thread;
import core.time : dur;

import sparkles.core_cli.process_utils : parseCpuTicksFromStat, CpuTicks;

// _SC_CLK_TCK is 2 on Linux; sysconf returns the scheduler tick rate (~100 Hz),
// the unit of utime/stime in /proc/<pid>/stat.
private enum _SC_CLK_TCK = 2;

extern (C) long sysconf(int name) @nogc nothrow;

enum Scenario
{
    idle,
    render,
    churn,
}

struct Config
{
    string[] binaries;
    Scenario[] scenarios;
    int reps = 3;
    double warmupSecs = 3.0;
    double windowSecs = 8.0;
    int cols = 100;
    int rows = 30;
    string keepStreams; // if set, write streams here and keep them
}

// --- Deterministic workload streams ----------------------------------------

// A dense full screen: every cell carries a bold+italic+underline glyph with a
// distinct 256-color fg/bg, the heaviest per-cell draw the renderer supports.
// Painted once, with the cursor parked, so nothing changes afterwards (idle).
private string fillStream(int cols, int rows)
{
    auto w = appender!string;
    w ~= "\x1b[2J\x1b[H";
    foreach (line; 1 .. rows + 1)
    {
        w ~= format("\x1b[%d;1H", line);
        foreach (col; 1 .. cols + 1)
        {
            const index = line + col;
            const fg = index % 156 + 100;
            const bg = 255 - index % 156 + 100;
            const ch = cast(char)('A' + (index % 26));
            w ~= format("\x1b[38;5;%d;48;5;%d;1;3;4m%c", fg, bg, ch);
        }
    }
    w ~= "\x1b[H";
    return w[];
}

// vtebench-style `dense_cells`: repaint the entire grid `passes` times, cycling
// the glyph and colors each pass so every frame the renderer draws is a full,
// distinct repaint. Wrapped in the alternate screen.
private string denseStream(int cols, int rows, int passes)
{
    auto w = appender!string;
    w ~= "\x1b[?1049h";
    int offset = 0;
    foreach (_; 0 .. passes)
    {
        foreach (ch; "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        {
            w ~= "\x1b[H";
            foreach (line; 1 .. rows + 1)
                foreach (col; 1 .. cols + 1)
                {
                    const index = line + col + offset;
                    const fg = index % 156 + 100;
                    const bg = 255 - index % 156 + 100;
                    w ~= format("\x1b[38;5;%d;48;5;%d;1;3;4m%c", fg, bg, ch);
                }
            offset++;
        }
    }
    w ~= "\x1b[?1049l";
    return w[];
}

// The shell command run inside the terminal for a scenario. The terminal joins
// trailing args and runs them via `$SHELL -c`, so a single string is fine.
private string workload(Scenario s, string streamDir)
{
    final switch (s)
    {
        case Scenario.idle:
        case Scenario.render:
            // Paint once, then sit idle well past the measurement window. The
            // render scenario additionally forces a redraw every frame via the
            // env var set in `measure`, so the same static screen exercises the
            // full render path instead of being skipped.
            return format("cat %s; sleep 600", buildPath(streamDir, "fill.vt"));
        case Scenario.churn:
            // Repaint continuously for the whole run.
            return format("while :; do cat %s; done", buildPath(streamDir, "dense.vt"));
    }
}

// --- Measurement ------------------------------------------------------------

private ulong cpuTicks(int pid)
{
    auto stat = readText(format("/proc/%d/stat", pid));
    auto parsed = parseCpuTicksFromStat(stat);
    return parsed.hasValue ? parsed.value.total : 0;
}

struct Sample
{
    double cpuPercent; // average % of one core over the window
    bool ok;
}

// Launch `binary` against `scenario`, let it warm up, then measure the CPU ticks
// it (the terminal process itself) accumulates over `windowSecs`.
private Sample measure(ref const Config cfg, string binary, Scenario scenario, string streamDir)
{
    auto devnull = File("/dev/null", "w");
    auto args = [binary, "--exit-behavior", "hold", "--", workload(scenario, streamDir)];

    // The render scenario forces a full redraw every frame so the render path is
    // measured in isolation rather than skipped on the static screen.
    string[string] env = environment.toAA;
    if (scenario == Scenario.render)
        env["SPARKLES_BENCH_FORCE_REDRAW"] = "1";

    Pid pid;
    try
        pid = spawnProcess(args, stdin, devnull, devnull, env);
    catch (ProcessException e)
    {
        stderr.writeln("  ! failed to spawn ", binary, ": ", e.msg);
        return Sample(0, false);
    }

    // SIGTERM the terminal on the way out; closing its pty master in turn
    // SIGHUPs the workload shell, so nothing is left running.
    void cleanup()
    {
        try { kill(pid); wait(pid); } catch (Exception) {}
    }
    scope (exit) cleanup();

    const id = pid.processID;
    Thread.sleep(dur!"msecs"(cast(long)(cfg.warmupSecs * 1000)));

    ulong t0;
    try
        t0 = cpuTicks(id);
    catch (FileException)
    {
        stderr.writeln("  ! ", baseName(binary), " exited before warmup finished");
        return Sample(0, false);
    }

    Thread.sleep(dur!"msecs"(cast(long)(cfg.windowSecs * 1000)));

    ulong t1;
    try
        t1 = cpuTicks(id);
    catch (FileException)
    {
        stderr.writeln("  ! ", baseName(binary), " exited during the window");
        return Sample(0, false);
    }

    const clk = sysconf(_SC_CLK_TCK) > 0 ? sysconf(_SC_CLK_TCK) : 100;
    const cpuSecs = cast(double)(t1 - t0) / clk;
    return Sample(100.0 * cpuSecs / cfg.windowSecs, true);
}

// --- Reporting --------------------------------------------------------------

struct Result
{
    double mean;
    double lo;
    double hi;
    int n;
}

private Result aggregate(const(Sample)[] samples)
{
    Result r;
    double sum = 0;
    r.lo = double.max;
    r.hi = -double.max;
    foreach (s; samples)
    {
        if (!s.ok) continue;
        sum += s.cpuPercent;
        r.lo = min(r.lo, s.cpuPercent);
        r.hi = max(r.hi, s.cpuPercent);
        r.n++;
    }
    r.mean = r.n ? sum / r.n : 0;
    if (r.n == 0) { r.lo = 0; r.hi = 0; }
    return r;
}

void main(string[] args)
{
    import std.getopt;

    Config cfg;
    string scenarioOpt = "all";

    auto help = getopt(
        args,
        "scenario", "Scenario: idle | churn | all (default: all)", &scenarioOpt,
        "reps", "Repetitions per (binary, scenario) (default: 3)", &cfg.reps,
        "warmup", "Warmup seconds before sampling (default: 3)", &cfg.warmupSecs,
        "window", "Sampling window in seconds (default: 8)", &cfg.windowSecs,
        "cols", "Grid columns for the workload (default: 100)", &cfg.cols,
        "rows", "Grid rows for the workload (default: 30)", &cfg.rows,
        "keep-streams", "Write generated streams to DIR and keep them", &cfg.keepStreams,
    );

    cfg.binaries = args[1 .. $];

    if (help.helpWanted || cfg.binaries.length == 0)
    {
        defaultGetoptPrinter(
            "Benchmark the sparkles terminal's render CPU.\n\n" ~
            "Usage: terminal-benchmark [options] <terminal-binary> [<terminal-binary>...]\n\n" ~
            "Measures each binary's own CPU over a fixed window while it renders a\n" ~
            "deterministic workload. Pass two binaries (e.g. before/after a change) to\n" ~
            "compare. Requires a display (the terminal opens a GL window).",
            help.options);
        return;
    }

    switch (scenarioOpt)
    {
        case "idle":   cfg.scenarios = [Scenario.idle]; break;
        case "render": cfg.scenarios = [Scenario.render]; break;
        case "churn":  cfg.scenarios = [Scenario.churn]; break;
        case "all":    cfg.scenarios = [Scenario.idle, Scenario.render, Scenario.churn]; break;
        default:
            stderr.writeln("Unknown scenario: ", scenarioOpt, " (use idle | render | churn | all)");
            return;
    }

    // Generate streams into a temp dir (or the kept dir).
    string streamDir = cfg.keepStreams.length ? cfg.keepStreams : tempStreamDir();
    mkdirRecurse(streamDir);
    std.file.write(buildPath(streamDir, "fill.vt"), fillStream(cfg.cols, cfg.rows));
    std.file.write(buildPath(streamDir, "dense.vt"), denseStream(cfg.cols, cfg.rows, 20));

    writefln("# sparkles terminal benchmark");
    writefln("# grid %dx%d, %d rep(s), %.0fs warmup, %.0fs window",
        cfg.cols, cfg.rows, cfg.reps, cfg.warmupSecs, cfg.windowSecs);
    writefln("# streams: %s", streamDir);
    writeln();

    // Column header.
    writef("%-22s", "scenario \\ binary");
    foreach (b; cfg.binaries)
        writef(" %18s", baseName(b));
    writeln();

    foreach (scenario; cfg.scenarios)
    {
        writef("%-22s", scenarioName(scenario));
        foreach (b; cfg.binaries)
        {
            Sample[] samples;
            foreach (_; 0 .. cfg.reps)
                samples ~= measure(cfg, b, scenario, streamDir);
            const r = aggregate(samples);
            if (r.n == 0)
                writef(" %18s", "FAILED");
            else
                writef(" %16.1f%%", r.mean);
            stdout.flush();
        }
        writeln();
    }

    if (cfg.keepStreams.length == 0)
    {
        try { rmdirRecurse(streamDir); } catch (Exception) {}
    }

    writeln();
    writeln("# values are average % of one core over the window (lower is better)");
}

private string scenarioName(Scenario s)
{
    final switch (s)
    {
        case Scenario.idle:   return "idle (static screen)";
        case Scenario.render: return "render (forced redraw)";
        case Scenario.churn:  return "churn (full repaint)";
    }
}

private string tempStreamDir()
{
    import std.conv : to;
    // No timestamp/random needed; the pid is enough for a unique scratch dir.
    return buildPath(tempDir(), "terminal-benchmark-" ~ thisProcessID.to!string);
}
