#!/usr/bin/env rdmd
module run_benchmarks;

import std.stdio;
import std.process;
import std.string;
import std.array;
import std.regex;
import std.conv;

void main()
{
    writeln("=================================================");
    writeln("  Sparkles Algebraic Effect System Benchmarks");
    writeln("=================================================");
    writeln();

    // 1. Run the D benchmarks
    writeln("--> Compiling and running D Benchmarks (Release Mode)...");
    auto dRes = executeShell("cd libs/effects-benchmarks && dub run -b release -q");
    if (dRes.status != 0)
    {
        writeln("Error running D benchmarks:");
        writeln(dRes.output);
        return;
    }

    // We expect the D runner to output something like:
    // Benchmark Results (D Implementations):
    // ╭───────────────────────┬────────────┬───────────╮
    // │ Implementation        │ Iterations │ Time (ms) │
    // ...
    // Let's just print it directly.
    writeln(dRes.output.strip());
    writeln();

    // 2. Run the TypeScript benchmarks
    writeln("--> Running TypeScript Mitata Benchmarks...");
    // We pipe Mitata to cat or use NO_COLOR if needed, but Mitata usually figures out if it's not a TTY.
    // However, executeShell captures output so colors might be kept or stripped depending on Mitata's logic.
    // Let's force colors off in Mitata via NO_COLOR=1 just in case, though the visual is nice.
    auto tsRes = executeShell("cd libs/effects-benchmarks/ts && NO_COLOR=1 npx tsx bench.ts");
    if (tsRes.status != 0)
    {
        writeln("Error running TypeScript benchmarks:");
        writeln(tsRes.output);
        return;
    }

    writeln(tsRes.output.strip());
    writeln();

    writeln("=================================================");
    writeln("  All benchmarks complete.");
    writeln("=================================================");
}
