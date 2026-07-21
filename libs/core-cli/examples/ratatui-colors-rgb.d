#!/usr/bin/env dub
/+ dub.sdl:
    name "ratatui-colors-rgb"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
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
// The per-frame render is allocation-free: the frame is built one row at a time
// into a single reused inline `SmallBuffer` (never heap-backed for a real
// terminal width) and the row builders are `@nogc`, so the compiler proves the
// hot loop performs no GC allocation.
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
alias RowBuffer = SmallBuffer!(char, 131_072);

/// Set by the SIGINT handler; the frame loop checks it and exits so the
/// `scope (exit)` cleanup runs (restoring the cursor and primary screen).
__gshared bool stop = false;
extern (C) void onSigint(int) nothrow @nogc { stop = true; }

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
        row.clear();
        writeTitle(row, width, -1);
        stdout.rawWrite(row[]);
        foreach (ry; 0 .. rows)
        {
            row.clear();
            writeSpectrumRow(row, cast(uint) ry, width, cast(uint)(rows * 2), 0, caps.colorDepth);
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
            writeSpectrumRow(row, cast(uint) ry, width, cast(uint)(rows * 2), i, caps.colorDepth);
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

/// One spectrum row (a leading `\n` then `width` half-block cells). `fg` is the
/// top pixel, `bg` the pixel below; `writeStyleTransition` emits only the SGR
/// delta between adjacent cells. Allocation-free — the compiler enforces it via
/// `@nogc`.
void writeSpectrumRow(ref RowBuffer w, uint ry, uint width, uint pixelRows,
    size_t frameIdx, ColorDepth depth) @nogc
{
    w ~= '\n';
    auto cur = TermStyle.init;
    foreach (x; 0 .. width)
    {
        const top = spectrum(x, ry * 2, frameIdx, width, pixelRows);
        const bottom = spectrum(x, ry * 2 + 1, frameIdx, width, pixelRows);
        const next = TermStyle(fg: top, bg: bottom);
        writeStyleTransition(w, cur, next, depth);
        w ~= "▀";
        cur = next;
    }
    writeStyleTransition(w, cur, TermStyle.init, depth); // clear bg at row end
}

/// The color of pixel `(x, py)` at animation frame `frameIdx`: hue rides `x`
/// (scrolled by the frame count) around the wheel, brightness rises up the
/// column. ratatui uses perceptually-uniform Okhsv; this uses plain HSV, which
/// is a punchier — if less uniform — rainbow for the demo.
Color spectrum(uint x, uint py, size_t frameIdx, uint width, uint pixelRows) @nogc
{
    const xi = (x + frameIdx) % width;
    const hue = 360.0 * xi / width;
    const value = pixelRows ? cast(double)(pixelRows - py) / pixelRows : 1.0;
    ubyte r, g, b;
    hsvToRgb(hue, 1.0, value, r, g, b);
    return Color.fromRgb(r, g, b);
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
