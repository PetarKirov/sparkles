#!/usr/bin/env dub
/+ dub.sdl:
    name "meter"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// Proportional bars (`sparkles.core_cli.ui.meter`): eighth-cell precision
// meters, the count/max form, the ASCII fallback, and the composed
// `ProgressBar` / `ProgressLine` one-liners that live regions repaint.

module meter_example;

import core.time : msecs;
import std.stdio : writefln, writeln;

import sparkles.core_cli.ui.meter : meter, meterGlyphs, ProgressBar;
import sparkles.core_cli.ui.progress : ProgressLine, spinnerFrame;

void main()
{
    // Fractions at eighth-cell precision (▏▎▍▌▋▊▉█).
    foreach (pct; [0.0, 0.125, 0.33, 0.5, 0.66, 0.875, 1.0])
        writefln!"%5.1f%% |%s|"(pct * 100, meter(pct, 16));

    // Count/max form + the ASCII fallback charset.
    writeln("7 of 9:  |", meter(7, 9, 16), "|");
    writeln("ascii:   |", meter(7, 9, 16, meterGlyphs(false)), "|");

    // The determinate progress bar: meter + right-justified counter.
    writeln(ProgressBar(done: 5, total: 40, barWidth: 20));
    writeln(ProgressBar(done: 38, total: 40, barWidth: 20));

    // The indeterminate sibling: spinner + counter (+ elapsed when set).
    writeln(ProgressLine(frame: 3, done: 12, total: 40, elapsed: 1500.msecs));
    writeln("spinner frames: ", spinnerFrame(0), spinnerFrame(1), spinnerFrame(2));
}
