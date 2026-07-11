#!/usr/bin/env dub
/+ dub.sdl:
    name "gc_uaf_blindspot"
    platforms "linux"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
    targetPath "build"
+/
/**
 * The AddressSanitizer GC blind spot: a use-after-free inside GC-managed
 * memory is invisible to ASan, while the identical bug on `malloc`/`free`
 * memory is caught — demonstrated as a self-verifying contrast pair.
 *
 * Two child-process demonstrations (the parent re-execs itself and asserts on
 * each child's exit code and stderr report):
 *
 *   1. `GC.malloc` -> `GC.free` -> read. The D GC allocates its pools with
 *      `mmap` (`core/internal/gc/os.d`, `os_mem_map`) and recycles memory
 *      internally, so freed GC memory never passes through ASan's intercepted
 *      `free` and its shadow is never poisoned: the child reads a garbage
 *      value and exits 0 — ASan reports nothing. The blind spot.
 *   2. `core.stdc.stdlib.malloc` -> `free` -> read. The C allocator *is*
 *      intercepted (quarantine + shadow poisoning), so the same read dies
 *      with `heap-use-after-free`, a symbolized `file:line`, and exit 1.
 *
 * Companion to docs/research/sanitizers/d-toolchain.md
 *   § "The GC blind spot: ASan cannot see GC pools".
 *
 * Run with: dub run --single gc-uaf-blindspot.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4), LDC 1.41.0
 * (LLVM 18.1.8). nixpkgs LDC ships no compiler-rt, so the ASan runtime is GCC
 * 15.2.0's `libasan.so.8` via LDC's `linker-gcc.cpp` fallback (`-fsanitize=
 * address` handed to the C-compiler link driver); it self-symbolizes without
 * `llvm-symbolizer`.
 *
 * Portability: builds without instrumentation (DMD has no `-fsanitize`; the
 * flag is gated `platform="ldc"`), in which case — detected at compile time
 * via the `LDC_AddressSanitizer` predefined version — the probe prints a
 * `SKIP:` line and exits 0 so CI stays green on any host.
 */
module gc_uaf_blindspot;

import std.stdio : writefln, writeln;

version (LDC_AddressSanitizer)
    private enum instrumented = true;
else
    private enum instrumented = false;

/// Name of the env var that selects the faulty child leg.
private enum childVar = "GC_UAF_BLINDSPOT_CHILD";

/// Child leg 1: use-after-free entirely inside GC-managed memory.
/// ASan never sees the GC's mmap'd pools, so this runs to completion.
private int runGcLeg()
{
    import core.memory : GC;

    int* p = cast(int*) GC.malloc(64);
    p[0] = 42;
    GC.free(p);
    // Deliberate read-after-free of GC memory (the value is garbage).
    writefln("gc leg: read-after-GC.free = %s (not flagged)", p[0]);
    return 0;
}

/// Child leg 2: the identical bug on the intercepted C allocator.
/// ASan poisons freed memory, so this read aborts with a report.
private int runMallocLeg()
{
    import core.stdc.stdlib : free, malloc;

    int* p = cast(int*) malloc(64);
    p[0] = 42;
    free(p);
    writefln("malloc leg: read-after-free = %s (should never print)", p[0]);
    return 0;
}

/// Re-execs this binary with `childVar=leg`, captures combined output, and
/// returns (exitCode, output).
private auto runChild(string leg)
{
    import std.process : environment, escapeShellCommand, executeShell;

    // detect_leaks=0: keep the asserted exit codes purely about the
    // demonstrated defect (LSan's exit-at-process-end would add exit 23).
    const env = [
        childVar: leg,
        "ASAN_OPTIONS": "detect_leaks=0",
    ];
    import std.file : thisExePath;

    return executeShell(escapeShellCommand(thisExePath) ~ " 2>&1", env);
}

version (linux) private int run()
{
    import std.algorithm.searching : canFind;
    import std.process : environment;

    const leg = environment.get(childVar);
    if (leg == "gc")
        return runGcLeg();
    if (leg == "malloc")
        return runMallocLeg();

    static if (!instrumented)
    {
        writeln("SKIP: built without AddressSanitizer instrumentation ",
            "(DMD has no -fsanitize; LDC-only dflags are platform-gated)");
        return 0;
    }
    else
    {
        // Parent: run both legs and verify the contrast.
        const gc = runChild("gc");
        assert(gc.status == 0,
            "expected the GC use-after-free to go UNdetected (the blind spot)");
        assert(!gc.output.canFind("AddressSanitizer"),
            "expected no ASan report for GC memory");
        writeln("proved: use-after-free inside GC pools is invisible to ASan");

        const mal = runChild("malloc");
        assert(mal.status != 0,
            "expected ASan to abort the malloc/free use-after-free child");
        assert(mal.output.canFind("heap-use-after-free"),
            "expected a heap-use-after-free report; got:\n" ~ mal.output);
        writefln("proved: the same bug on malloc/free dies with " ~
            "heap-use-after-free (child exit %s)", mal.status);

        writeln("OK: ASan sees the C heap but not the GC's mmap'd pools");
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        writeln("SKIP: this probe records Linux behavior (platforms \"linux\")");
        return 0;
    }
}
