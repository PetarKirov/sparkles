module sparkles.effects_benchmarks.app;

import std.datetime.stopwatch : StopWatch, Duration;
import std.stdio : writeln;
import std.conv : to;
import std.process : executeShell;
import std.string : split, strip;
import std.datetime.systime : Clock;
import core.volatile : volatileLoad, volatileStore;
import sparkles.core_cli.ui.table : drawTable;

import sparkles.effects_direct;
import sparkles.effects_ts;

enum ITERS = 100_000_000;

__gshared uint sink;

struct NativeEnv { int a, b, c; }
void runNative(int val1, int val2, int val3) {
    NativeEnv env = NativeEnv(val1, val2, val3);
    foreach (i; 0 .. ITERS) {
        uint val = volatileLoad(&sink);
        volatileStore(&sink, val + env.a + env.b + env.c);
    }
}

struct CapA { int v; int ask() { return v; } }
struct CapB { int v; int ask() { return v; } }
struct CapC { int v; int ask() { return v; } }

void runDirect(Ctx)(ref Ctx ctx) {
    foreach (i; 0 .. ITERS) {
        uint val = volatileLoad(&sink);
        volatileStore(&sink, val + ctx.get!CapA.ask() + ctx.get!CapB.ask() + ctx.get!CapC.ask());
    }
}

void runEffectTS(int val1, int val2, int val3) {
    // In Effect-TS, we construct the pipeline of descriptions.
    // We measure AST construction overhead.
    foreach (i; 0 .. ITERS) {
        auto program = ask!CapA()
            .flatMap!(a => ask!CapB())
            .flatMap!(b => ask!CapC())
            .flatMap!(c => succeed(1))
            .provide(CapA(val1))
            .provide(CapB(val2))
            .provide(CapC(val3));

        uint val = volatileLoad(&sink);
        volatileStore(&sink, val + 1);
    }
}

void main() {
    // Defeat optimizers with a runtime seed
    long seed = Clock.currStdTime();
    int val1 = cast(int)(seed % 10);
    int val2 = val1 + 1;
    int val3 = val1 + 2;

    string[][] results = [
        ["Implementation", "Iterations", "Time (ms)"]
    ];

    StopWatch sw;

    // 1. Native D
    sw.start();
    runNative(val1, val2, val3);
    sw.stop();
    results ~= ["Native D", ITERS.to!string, sw.peek.total!"msecs".to!string];
    sw.reset();

    // 2. Direct-Style
    auto ctx = Context!(CapA, CapB, CapC)(CapA(val1), CapB(val2), CapC(val3));
    sw.start();
    runDirect(ctx);
    sw.stop();
    results ~= ["D Direct-Style", ITERS.to!string, sw.peek.total!"msecs".to!string];
    sw.reset();

    // 3. Effect-TS Style
    sw.start();
    runEffectTS(val1, val2, val3);
    sw.stop();
    results ~= ["D Effect-TS Builder", ITERS.to!string, sw.peek.total!"msecs".to!string];

    // 4. TS benchmarks
    writeln("Running TypeScript benchmarks... (this might take a few seconds)");
    auto tsRes = executeShell("cd ts && npx tsx bench.ts");
    if (tsRes.status == 0) {
        foreach (line; tsRes.output.split("\n")) {
            line = line.strip();
            if (line.length > 0) {
                auto parts = line.split(",");
                if (parts.length == 3) {
                    results ~= parts;
                }
            }
        }
    } else {
        writeln("Warning: failed to run TS benchmarks: ", tsRes.output);
    }

    writeln("\nBenchmark Results:");
    writeln(drawTable(results));
}
