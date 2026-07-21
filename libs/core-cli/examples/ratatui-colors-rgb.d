#!/usr/bin/env dub
/+ dub.sdl:
    name "ratatui-colors-rgb"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"

    # The default config for `dub run` (the demo). Declaring `unittest` below
    # suppresses dub's auto-generated application config, so name it explicitly.
    configuration "application" {
        targetType "executable"
    }

    configuration "unittest" {
        # The frame-render fps benchmark (see the `version (unittest)` block
        # below) runs on sparkles:test-runner; the shim pulls the prebuilt impl.
        dependency "sparkles:test-runner" path="../../.."
        dflags "-checkaction=context" "-allinst"
        dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
        dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
        lflags "--export-dynamic" platform="linux-ldc"
    }

    # Release codegen for meaningful numbers:
    #   dub test --single ratatui-colors-rgb.d -b bench -- --bench --group-by=sink
    buildType "bench" {
        buildOptions "unittests" "releaseMode" "optimize" "inline"
        dflags "-mcpu=native" "-O3" "-allinst" platform="ldc"
    }
+/
// ci: build-only

module ratatui_colors_rgb_example;

// A port of ratatui's `colors_rgb` example (examples/colors_rgb.rs) to
// sparkles:core-cli.
//
// Animates the full 24-bit RGB spectrum across the terminal. Each character is
// the upper-half-block `▀` with its foreground set to one pixel and its
// background to the pixel below it, so one text row shows two pixel rows; the
// hue scrolls sideways by the frame count. Colors are emitted through
// `writeStyleTransition` with the detected `ColorDepth`, so on a non-truecolor
// terminal they fold to the 256 or 16 palette automatically.
//
// Full-screen animation drives `sparkles.base.term_control` directly (the alt
// screen + synchronized output). It runs until Ctrl+C on a terminal; when
// stdout is piped it prints a single static frame instead (so it stays
// pipe-safe). `--frames N` bounds the run; `--fps N` sets the target rate.
//
// Colors are cached: the HSV→RGB grid is computed once and rebuilt only on a
// resize (`SpectrumCache`, like ratatui's `setup_colors`); each frame is then a
// cached lookup scrolled by the frame count, so no HSV math runs per frame. The
// render itself is allocation-free: the frame is built one row at a time into a
// single reused inline `SmallBuffer` (never heap-backed for a real terminal
// width) and the row builders are `@nogc`, so the compiler proves the hot loop
// performs no GC allocation.
//
// The bottom of this file also carries a `@benchmark` (under `version (unittest)`)
// that measures the uncapped frame-render fps at several terminal sizes — see it
// for the `dub test … -b bench` invocation.
//
//   dub run --single ratatui-colors-rgb.d
//   dub run --single ratatui-colors-rgb.d -- --frames 300 --fps 30

import core.stdc.signal : signal, SIGINT;
import core.thread : Thread;
import core.time : dur, MonoTime;

import std.conv : to;
import std.math : abs, floor;
import std.stdio : stdout, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : Color, ColorDepth;
import sparkles.base.term_control : CtlSeq;
import sparkles.base.term_style : TermStyle, writeStyleTransition;
import sparkles.base.text.writers : writeInteger;
import sparkles.core_cli.term_caps : detectTermCaps, terminalSize;

/// One built row (title or a spectrum line) of the frame. Sized so it never
/// spills to the heap for any realistic terminal width (~40 bytes/cell), which
/// keeps `clear()` — and therefore the whole loop — allocation-free.
// `unique` (move-only) mode: this buffer is a sole owner that is only ever
// built, sliced, and cleared in place — never copied or shared — so it opts out
// of the copy-on-write machinery. That drops the per-`put` alias check on the
// hot render path (~10% faster frame render here).
alias RowBuffer = SmallBuffer!(char, 131_072, true);

/// Set by the SIGINT handler; the frame loop checks it and exits so the
/// `scope (exit)` cleanup runs (restoring the cursor and primary screen).
__gshared bool stop = false;
extern (C) void onSigint(int) nothrow @nogc { stop = true; }

// In a `dub test` (unittest) build the runner provides the entry point, so the
// demo's `main` is compiled only for the normal `dub run` build.
version (unittest) {} else
void main(string[] args)
{
    size_t maxFrames = 0; // 0 = run until Ctrl+C
    uint fpsTarget = 60;
    foreach (i, a; args[1 .. $])
    {
        if (a == "--frames" && i + 2 < args.length) maxFrames = args[i + 2].to!size_t;
        else if (a == "--fps" && i + 2 < args.length) fpsTarget = args[i + 2].to!uint;
        else if (a == "--help" || a == "-h")
        {
            writeln("colors-rgb — animated 24-bit RGB spectrum (ratatui colors_rgb demo)\n"
                ~ "  --frames N   stop after N frames (default: until Ctrl+C)\n"
                ~ "  --fps N      target frame rate (default 60)");
            return;
        }
    }
    if (fpsTarget < 1) fpsTarget = 1;

    const caps = detectTermCaps();
    if (caps.colorDepth == ColorDepth.none)
    {
        writeln("colors-rgb needs a color terminal (truecolor renders best).");
        return;
    }

    uint width = caps.size.width ? caps.size.width : 80;
    uint height = caps.size.height ? caps.size.height : 24;

    RowBuffer row;

    // Piped / non-tty: emit one static frame and exit — never send alt-screen or
    // cursor-control sequences to a file.
    if (!caps.tty)
    {
        const rows = height >= 2 ? height - 1 : height;
        SpectrumCache cache;
        cache.resize(width, cast(uint)(rows * 2));
        row.clear();
        writeTitle(row, width, -1);
        stdout.rawWrite(row[]);
        foreach (ry; 0 .. rows)
        {
            row.clear();
            writeSpectrumRow(row, cache, cast(uint) ry, 0, caps.colorDepth);
            stdout.rawWrite(row[]);
        }
        stdout.rawWrite("\n");
        return;
    }

    stdout.rawWrite(CtlSeq.enterAltScreen);
    stdout.rawWrite(CtlSeq.hideCursor);
    scope (exit)
    {
        stdout.rawWrite(CtlSeq.showCursor);
        stdout.rawWrite(CtlSeq.exitAltScreen);
        stdout.flush();
    }
    signal(SIGINT, &onSigint);

    auto fpsClock = MonoTime.currTime;
    size_t sinceTick;
    double fps = 0;
    uint prevW = 0, prevH = 0;
    SpectrumCache cache; // the HSV→RGB grid, rebuilt only when the size changes
    const frameBudget = dur!"msecs"(1000 / fpsTarget);

    for (size_t i = 0; !stop && (maxFrames == 0 || i < maxFrames); ++i)
    {
        // Re-read the size each frame so a resize is picked up.
        const sz = terminalSize();
        if (sz.width) width = sz.width;
        if (sz.height) height = sz.height;
        const resized = width != prevW || height != prevH;
        prevW = width;
        prevH = height;

        const rows = height >= 2 ? height - 1 : height;
        cache.resize(width, cast(uint)(rows * 2)); // no-op unless the size changed

        // Preamble + title as the first write; clear stale cells only on resize
        // (a full redraw covers the screen otherwise, so no per-frame flicker).
        row.clear();
        row ~= cast(string) CtlSeq.syncBegin;
        row ~= cast(string) CtlSeq.cursorHome;
        if (resized)
            row ~= cast(string) CtlSeq.eraseDisplay;
        writeTitle(row, width, fps);
        stdout.rawWrite(row[]);

        foreach (ry; 0 .. rows)
        {
            row.clear();
            writeSpectrumRow(row, cache, cast(uint) ry, i, caps.colorDepth);
            stdout.rawWrite(row[]);
        }
        stdout.rawWrite(CtlSeq.syncEnd);
        stdout.flush();

        ++sinceTick;
        const elapsed = (MonoTime.currTime - fpsClock).total!"msecs";
        if (elapsed >= 500)
        {
            fps = sinceTick * 1000.0 / elapsed;
            sinceTick = 0;
            fpsClock = MonoTime.currTime;
        }
        Thread.sleep(frameBudget);
    }
}

/// The title row: name on the left, fps on the right, padded to `width`. A `fps`
/// below zero hides the readout (the static frame). Allocation-free.
void writeTitle(ref RowBuffer w, uint width, double fps) @nogc
{
    static immutable left = "colors-rgb - Ctrl+C to quit";

    SmallBuffer!(char, 24) right;
    if (fps >= 0)
    {
        const scaled = cast(uint)(fps * 10.0 + 0.5); // one decimal, no float formatter
        writeInteger(right, scaled / 10);
        right ~= '.';
        writeInteger(right, scaled % 10);
        right ~= " fps";
    }

    w ~= left;
    const used = left.length + right.length;
    const gap = width > used ? width - used : 1;
    foreach (_; 0 .. gap)
        w ~= ' ';
    w ~= right[];
}

/// A precomputed HSV→RGB grid — one `Color` per pixel column × pixel row —
/// rebuilt only when the terminal size changes (the equivalent of ratatui's
/// `setup_colors`). The per-frame render is then a cached lookup with the column
/// scrolled by the frame count, so no HSV math happens in the hot loop.
///
/// ratatui uses perceptually-uniform Okhsv; this uses plain HSV, a punchier — if
/// less uniform — rainbow for the demo.
struct SpectrumCache
{
    private Color[] colors; // row-major: colors[py * width + x]
    uint width;
    uint pixelRows;

    /// (Re)compute the grid for `width × pixelRows`; a no-op when the size is
    /// unchanged. The one allocation lives here (on resize) — never in the hot
    /// loop, so the per-frame render stays allocation-free.
    void resize(uint w, uint pr)
    {
        const n = cast(size_t) w * pr;
        if (w == width && pr == pixelRows && colors.length == n)
            return;
        width = w;
        pixelRows = pr;
        colors.length = n;
        foreach (py; 0 .. pr)
            foreach (x; 0 .. w)
            {
                const hue = 360.0 * x / w;
                const value = pr ? cast(double)(pr - py) / pr : 1.0;
                ubyte r, g, b;
                hsvToRgb(hue, 1.0, value, r, g, b);
                colors[py * w + x] = Color.fromRgb(r, g, b);
            }
    }

    /// The cached color of pixel column `x`, pixel row `py`, at animation frame
    /// `frameIdx` — the hue rides the column, scrolled by the frame count.
    Color at(uint x, uint py, size_t frameIdx) const @nogc
    {
        const xi = cast(uint)((x + frameIdx) % width);
        return colors[py * width + xi];
    }
}

/// One spectrum row (a leading `\n` then `cache.width` half-block cells). `fg` is
/// the top pixel, `bg` the pixel below; `writeStyleTransition` emits only the SGR
/// delta between adjacent cells. Allocation-free — the compiler enforces it via
/// `@nogc` (the colors are cached lookups, not recomputed here).
void writeSpectrumRow(ref RowBuffer w, in SpectrumCache cache, uint ry,
    size_t frameIdx, ColorDepth depth) @nogc
{
    w ~= '\n';
    auto cur = TermStyle.init;
    foreach (x; 0 .. cache.width)
    {
        const top = cache.at(x, ry * 2, frameIdx);
        const bottom = cache.at(x, ry * 2 + 1, frameIdx);
        const next = TermStyle(fg: top, bg: bottom);
        writeStyleTransition(w, cur, next, depth);
        w ~= "▀";
        cur = next;
    }
    writeStyleTransition(w, cur, TermStyle.init, depth); // clear bg at row end
}

/// HSV → RGB. `h` in [0, 360), `s`/`v` in [0, 1].
void hsvToRgb(double h, double s, double v, out ubyte r, out ubyte g, out ubyte b) @nogc
{
    const c = v * s;
    const hp = h / 60.0;
    const x = c * (1.0 - abs((hp % 2.0) - 1.0));
    double r1 = 0, g1 = 0, b1 = 0;
    if (hp < 1)      { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else             { r1 = c; b1 = x; }
    const m = v - c;
    ubyte q(double t) => cast(ubyte) floor((t + m) * 255.0 + 0.5);
    r = q(r1);
    g = q(g1);
    b = q(b1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark: uncapped frame-render throughput (fps) at different terminal sizes.
//
// Reuses the demo's own row builders (`writeTitle`/`writeSpectrumRow`) to render
// one full frame per timed iteration and write it to a real fd (`/dev/null`), so
// the write() syscall + buffer-copy overhead is counted; an in-memory (no-write)
// baseline is measured alongside, so the IO overhead is the mem→/dev/null delta.
// There is no `Thread.sleep` here — this is the raw render+IO ceiling. It lives
// under `version (unittest)` so the plain `dub run` demo build needs no
// test-runner dependency.
//
//   dub test --single ratatui-colors-rgb.d -b bench -- --bench --group-by=sink
//   RGB_BENCH_SIZES=120x40,320x90 RGB_BENCH_SINKS=devnull \
//       dub test --single ratatui-colors-rgb.d -b bench -- --bench
// ─────────────────────────────────────────────────────────────────────────────
version (unittest)
{
    import sparkles.test_runner.attributes : benchmark;
    import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;
    import std.stdio : File;

    private struct BenchSize { uint width, height; string label; }

    private immutable BenchSize[] benchSizes = [
        BenchSize(80, 24, "80x24"),
        BenchSize(120, 40, "120x40"),
        BenchSize(160, 48, "160x48"),
        BenchSize(240, 67, "240x67"),
        BenchSize(320, 90, "320x90"),
    ];

    version (Posix) private enum nullPath = "/dev/null";
    else            private enum nullPath = "NUL";

    /// Reusable per-case state: heap-allocated so the deferred `benchCase`
    /// closures all share one instance (the frame buffer and fd persist, and
    /// `frameIdx` advances between iterations to animate and defeat caching).
    private struct St
    {
        @disable this(this); // holds a File; only ever used via `new St` + pointer

        uint width, height;
        RowBuffer buf;      // reused; stays inline → render is allocation-free
        SpectrumCache cache; // built once per case (fixed size), then lookups only
        size_t frameIdx;
        bool toFd;
        File sink;          // /dev/null, opened once (when toFd)
    }

    @("colors-rgb.render")
    @benchmark
    @system
    unittest
    {
        bool any;
        foreach (const ref sz; benchSizes)
        {
            if (!benchEnvAllows("RGB_BENCH_SIZES", sz.label))
                continue;
            foreach (toFd; [false, true])
            {
                if (!benchEnvAllows("RGB_BENCH_SINKS", toFd ? "devnull" : "mem"))
                    continue;
                registerFrame(sz, toFd);
                any = true;
            }
        }
        if (!any)
            benchCase(name: "(filtered out)", timed: () {}, after: () {});
    }

    private void registerFrame(BenchSize sz, bool toFd)
    {
        auto st = new St;
        st.width = sz.width;
        st.height = sz.height;
        st.toFd = toFd;
        if (toFd)
            st.sink = File(nullPath, "wb");
        const rows0 = sz.height >= 2 ? sz.height - 1 : sz.height;
        st.cache.resize(sz.width, cast(uint)(rows0 * 2)); // untimed per-case setup

        const frameBytes = probeFrameBytes(sz.width, sz.height);

        benchCase(
            name: sz.label,
            labels: ["sink": toFd ? "/dev/null" : "mem"],
            timed: () { renderFrame(st); },
            after: () {},
            metrics: [
                // One frame per timed call → the rate column IS frames/sec (fps).
                Metric(unit: Unit("frame"), amount: 1.0, mode: Metric.Mode.rate),
                Metric(unit: Unit("B"), amount: cast(double) frameBytes, mode: Metric.Mode.rate),
                Metric(unit: Unit("B"), amount: cast(double) frameBytes, mode: Metric.Mode.level),
            ],
        );
    }

    /// Render one full frame (title + `H-1` spectrum rows) into the reused inline
    /// buffer, writing each row to the sink. Allocation-free in steady state.
    private void renderFrame(St* st)
    {
        const rows = st.height >= 2 ? st.height - 1 : st.height;

        st.buf.clear();
        writeTitle(st.buf, st.width, 60.0);
        emit(st);
        foreach (ry; 0 .. rows)
        {
            st.buf.clear();
            writeSpectrumRow(st.buf, st.cache, cast(uint) ry, st.frameIdx, ColorDepth.trueColor);
            emit(st);
        }
        if (st.toFd)
            st.sink.flush();
        ++st.frameIdx;
        blackBox(st.frameIdx);
    }

    private void emit(St* st)
    {
        if (st.toFd)
            st.sink.rawWrite(st.buf[]);
        else
            blackBox(st.buf[]);
    }

    /// Total bytes one frame writes at this size (trueColor) — for the B/s and
    /// bytes/frame metric columns. Frame 0 is representative (SGR-delta sizes
    /// vary only slightly across frames).
    private size_t probeFrameBytes(uint width, uint height)
    {
        const rows = height >= 2 ? height - 1 : height;
        SpectrumCache cache;
        cache.resize(width, cast(uint)(rows * 2));
        RowBuffer buf;
        size_t total;
        buf.clear();
        writeTitle(buf, width, 60.0);
        total += buf.length;
        foreach (ry; 0 .. rows)
        {
            buf.clear();
            writeSpectrumRow(buf, cache, cast(uint) ry, 0, ColorDepth.trueColor);
            total += buf.length;
        }
        return total;
    }

    private bool benchEnvAllows(string var, string name)
    {
        import std.algorithm : canFind, splitter;
        import std.process : environment;

        const v = environment.get(var, "");
        return v.length == 0 || v.splitter(',').canFind(name);
    }
}
