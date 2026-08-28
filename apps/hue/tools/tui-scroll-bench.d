#!/usr/bin/env dub
/+ dub.sdl:
    name "tui_scroll_bench"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// What a scroll actually costs, measured the way the user feels it.
//
// A terminal application's output IS its frame (the `tui-ab` argument), so
// the latency of a keystroke is measurable without instrumenting hue at all:
// write the key, then time how long the tty stays busy. The frame is done
// when the bytes stop arriving.
//
//   dub run --single apps/hue/tools/tui-scroll-bench.d -- \
//       --bin apps/hue/build/hue --file apps/hue/samples/dsv/files.csv \
//       --count 40
//
// Reports per-keystroke latency (median / p95 / max) and the bytes each frame
// wrote, which separates "hue thinks too long" from "hue writes too much".
// `--keys` takes the same escape vocabulary as `tui-ab` so any key can be the
// one under test; the default is one line down.
module tui_scroll_bench;

import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.signal : SIGKILL;
import core.sys.posix.unistd : read;
import core.time : Duration, MonoTime, msecs, nsecs;

import std.algorithm : map, max, sort, sum;
import std.array : appender, array, join, split;
import std.conv : text, to;
import std.process : Redirect, ProcessPipes, kill, pipeProcess, tryWait, wait;
import std.stdio : File, stderr, stdout, writefln, writeln;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

struct Args
{
    @(Option("bin|b", description: "The hue binary to measure"))
    string bin = "apps/hue/build/hue";

    @(Option("file|f", description: "The file to open in the viewer"))
    string file = "apps/hue/samples/dsv/files.csv";

    @(Option("args", description: "Extra arguments, before the file"))
    string extra;

    @(Option("cols", description: "Terminal width for the pty"))
    int cols = 220;

    @(Option("rows", description: "Terminal height for the pty"))
    int rows = 50;

    @(Option("keys|k", description: "The keystroke under test"))
    string keys = "down";

    @(Option("count|n", description: "Keystrokes to measure"))
    int count = 40;

    @(Option("settle", description: "Milliseconds of quiet that ends a frame"))
    int settle = 60;

    @(Option("warmup", description: "Milliseconds to wait for the first paint"))
    int warmup = 2500;

    @(Option("prekeys", description: "Keys to send before measuring (focus, mode)"))
    string prekeys;

    @(Option("dump", description: "Write the first paint and one frame here"))
    string dump;

    @(Option("cap", description: "Give up on a frame after this many ms"))
    int cap = 3000;

    @(Option("observe", description: "Instead of timing keys, watch the output "
        ~ "rate for this many ms (0 = off)"))
    int observe;
}

/// The `tui-ab` key vocabulary: names for the escape sequences a test drives.
string keyBytes(string name)
{
    switch (name)
    {
        case "down":      return "\x1b[B";
        case "up":        return "\x1b[A";
        case "left":      return "\x1b[D";
        case "right":     return "\x1b[C";
        case "enter":     return "\r";
        case "shiftright":return "\x1b[1;2C";
        case "shiftleft": return "\x1b[1;2D";
        case "pagedown":  return "\x1b[6~";
        case "pageup":    return "\x1b[5~";
        // SGR-1006 wheel events, aimed at the middle of the grid.
        case "wheeldown": return "\x1b[<65;60;20M";
        case "wheelup":   return "\x1b[<64;60;20M";
        default:          return name; // literal bytes
    }
}

/// Reads whatever is available until the stream stays quiet for `quiet`.
/// Returns the byte count; the caller times the call. `sink`, when given,
/// collects the bytes so a frame can be inspected.
size_t drain(int fd, Duration quiet, ubyte[]* sink = null,
    Duration cap = Duration.max)
{
    size_t total;
    ubyte[65536] buf;
    const quietMs = cast(int)(quiet.total!"msecs");
    const deadline = cap == Duration.max ? MonoTime.max : MonoTime.currTime + cap;
    for (;;)
    {
        if (MonoTime.currTime >= deadline)
            return total; // a frame that never settles is the finding
        pollfd p = {fd: fd, events: POLLIN};
        const ready = poll(&p, 1, quietMs);
        if (ready <= 0)
            return total; // the frame stopped writing
        const got = read(fd, buf.ptr, buf.length);
        if (got <= 0)
            return total;
        if (sink !is null)
            *sink ~= buf[0 .. got];
        total += got;
    }
}

/// Asks the session to quit, then kills it. A hue that has stopped answering
/// its input is one of the things this tool exists to catch, so the teardown
/// must never be the thing that hangs.
void shutdown(ref ProcessPipes pipes, int fd)
{
    pipes.stdin.rawWrite("q");
    pipes.stdin.flush();
    cast(void) drain(fd, 200.msecs, null, 1500.msecs);
    if (tryWait(pipes.pid).terminated)
        return;
    kill(pipes.pid, SIGKILL);
    cast(void) wait(pipes.pid);
}

int main(string[] argv)
{
    auto parsed = parseCli!Args(argv, HelpInfo("tui-scroll-bench",
        "Time a hue keystroke by how long the tty stays busy: the frame is "
        ~ "done when the bytes stop arriving.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    auto args = parsed.value;

    // `script` allocates the tty hue insists on (the tui-ab recipe).
    const extra = args.extra.length ? args.extra ~ " " : "";
    const inner = text("stty rows ", args.rows, " cols ", args.cols, "; exec ",
        args.bin, " view --tui ", extra, args.file);
    auto pipes = pipeProcess(["script", "-qec", inner, "/dev/null"],
        Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
    const fd = pipes.stdout.fileno;

    // The first paint is not the thing under test: let it finish. Its size is
    // the harness's own sanity check — a tiny first frame means the keys
    // below are being measured against an app that never painted.
    ubyte[] firstBytes;
    const spawned = MonoTime.currTime;
    const firstFrame = drain(fd, args.warmup.msecs,
        args.dump.length ? &firstBytes : null);
    const firstMs = (MonoTime.currTime - spawned - args.warmup.msecs)
        .total!"usecs" / 1000.0;
    writefln("first paint: %s bytes in %.1f ms", firstFrame, firstMs);
    if (args.dump.length)
        File(args.dump ~ ".first", "wb").rawWrite(firstBytes);

    // Focus/mode keys the measurement itself should not pay for. Capped: a
    // state whose repaint never settles must not wedge the harness.
    foreach (name; args.prekeys.length ? args.prekeys.split(",") : null)
    {
        pipes.stdin.rawWrite(keyBytes(name));
        pipes.stdin.flush();
        cast(void) drain(fd, args.settle.msecs, null, args.cap.msecs);
    }

    // Observation mode: no quiet-window assumption at all — just how many
    // bytes arrive per 100 ms while nobody touches the keyboard. An idle TUI
    // writes nothing; anything else is a repaint loop.
    if (args.observe > 0)
    {
        const until = MonoTime.currTime + args.observe.msecs;
        size_t total, buckets, busy;
        while (MonoTime.currTime < until)
        {
            const got = drain(fd, 5.msecs, null, 100.msecs);
            total += got;
            ++buckets;
            if (got > 0)
                ++busy;
        }
        writefln("observed %s ms: %s bytes in %s of %s 100ms windows (%.0f B/s)",
            args.observe, total, busy, buckets,
            total * 1000.0 / args.observe);
        shutdown(pipes, fd);
        return 0;
    }

    const key = keyBytes(args.keys);
    auto latencies = appender!(Duration[]);
    auto sizes = appender!(size_t[]);

    ubyte[] lastBytes;
    foreach (i; 0 .. args.count)
    {
        const start = MonoTime.currTime;
        pipes.stdin.rawWrite(key);
        pipes.stdin.flush();
        // The last frame is kept so a caller can confirm the keystroke moved
        // the view at all — a fast "frame" that changed nothing is not a fast
        // scroll, it is a dropped key.
        const wantLast = args.dump.length && i + 1 == args.count;
        if (wantLast)
            lastBytes.length = 0;
        const bytes = drain(fd, args.settle.msecs,
            wantLast ? &lastBytes : null, args.cap.msecs);
        if (wantLast)
            File(args.dump ~ ".last", "wb").rawWrite(lastBytes);
        // The quiet window is the frame's end marker, not part of its cost.
        const elapsed = MonoTime.currTime - start - args.settle.msecs;
        latencies ~= elapsed > Duration.zero ? elapsed : Duration.zero;
        sizes ~= bytes;
    }

    shutdown(pipes, fd);

    auto ms = latencies[].map!(d => d.total!"usecs" / 1000.0).array;
    ms.sort();
    auto bytes = sizes[].array;
    bytes.sort();

    double pick(double[] xs, double q) => xs[cast(size_t)(q * (xs.length - 1))];
    writefln("keystroke: %s   n=%s   %sx%s", args.keys, args.count,
        args.cols, args.rows);
    writefln("latency ms   median %.1f   p95 %.1f   max %.1f   mean %.1f",
        pick(ms, 0.5), pick(ms, 0.95), ms[$ - 1],
        ms.sum / ms.length);
    writefln("frame bytes  median %s   max %s",
        bytes[$ / 2], bytes[$ - 1]);
    return 0;
}
