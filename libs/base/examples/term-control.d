#!/usr/bin/env dub
/+ dub.sdl:
    name "term-control"
    dependency "sparkles:base" path="../../.."
    targetPath "build"
+/

// ci: build-only

// `sparkles.base.term_control`: the non-SGR control-sequence layer — fixed
// `CtlSeq` strings (erase, cursor visibility, alt screen, DEC 2026 synchronized
// output) plus `@nogc` writers for the parameterized moves. This demo redraws a
// countdown in place with carriage-return + erase-line, then shows a two-line
// region repainted with cursor-up — the primitives `LiveRegion` builds on.
// (Animated, so `ci` only builds it; run it in a terminal to watch.)

module term_control_example;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : stdout, write, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_control : CtlSeq, writeCursorUp;

void main()
{
    // One-line redraw: CR + erase-line, the classic progress-line framing.
    write(CtlSeq.hideCursor);
    scope (exit)
    {
        write(CtlSeq.showCursor);
        stdout.flush();
    }

    foreach_reverse (n; 1 .. 6)
    {
        write(CtlSeq.carriageReturn, CtlSeq.eraseLine, "countdown: ", n);
        stdout.flush();
        Thread.sleep(300.msecs);
    }
    writeln();

    // Multi-line redraw: cursor-up N + rewrite, framed in DEC 2026 synchronized
    // output so the update appears atomically (no tearing).
    writeln("status: starting");
    writeln("detail: -");
    foreach (step; 0 .. 4)
    {
        SmallBuffer!(char, 64) up;
        writeCursorUp(up, 2);

        write(CtlSeq.syncBegin);
        write(up[], CtlSeq.carriageReturn);
        write("status: working (", step + 1, "/4)", CtlSeq.eraseToEnd, "\n");
        write("detail: item #", step + 1, CtlSeq.eraseToEnd, "\n");
        write(CtlSeq.syncEnd);
        stdout.flush();
        Thread.sleep(300.msecs);
    }
    writeln("done");
}
