#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_tsan_data_race"
    platforms "linux"
    dflags "-fsanitize=thread" platform="ldc"
    dflags "-g"
    targetPath "build"
+/
/**
 * ThreadSanitizer catching a real D data race — and staying silent once the
 * same counter uses `core.atomic` — under LDC `-fsanitize=thread`.
 *
 * Three demonstrations, all driven from one parent process (the child-process
 * pattern: the probe re-execs itself with `SANITIZERS_TSAN_DEMO` set, so the
 * child wears the sanitizer report and the parent asserts on it):
 *
 *   1. Two threads doing unsynchronized `counter++` on a `__gshared int` —
 *      the child's stderr carries `WARNING: ThreadSanitizer: data race` and
 *      the child exits with TSan's default `exitcode=66` (compiler-rt
 *      `tsan_flags.cpp` overrides the common default of 1 with 66).
 *   2. A TSan report is $(B non-fatal by default) (`halt_on_error=false`):
 *      the racy child still prints its final `counter = ...` line — execution
 *      continued past the report; only the process exit code flips to 66 at
 *      `__tsan::Finalize`.
 *   3. The same counter incremented via `core.atomic.atomicOp!"+="` — LDC
 *      lowers it to an LLVM `atomicrmw` instruction, the TSan pass rewrites
 *      that to `__tsan_atomic32_fetch_add`, the runtime models it as
 *      synchronization: no report, exit 0.
 *
 * Companion to docs/research/sanitizers/tsan.md
 *   § "Runtime control and report capture" (the `TSAN_OPTIONS` defaults, exit
 *      code 66, and the halt-vs-continue behavior this probe asserts) — and
 *      § "D and druntime interaction" (the `shared` / `core.atomic` result).
 *
 * Run with: dub run --single tsan-data-race.d
 *
 * Environment recorded: Linux 6.18.26 (NixOS), AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8) with `-fsanitize=thread` linking GCC 15.2's `libtsan.so.2`
 * via LDC's gcc linker-driver fallback (`driver/linker-gcc.cpp`); the flag
 * defaults asserted here (`halt_on_error=false`, `exitcode=66`) were verified
 * against that runtime with `TSAN_OPTIONS=help=1`.
 *
 * Portability: a build without TSan instrumentation (DMD has no `-fsanitize`;
 * the dflags above are LDC-gated) detects the missing runtime via
 * `dlsym(RTLD_DEFAULT, "__tsan_init")` at run time, prints a `SKIP:` line,
 * and exits 0 so CI stays green on any host and compiler.
 */
module sanitizers_tsan_data_race;

version (linux)
{
    import core.atomic : atomicOp;
    import core.thread : Thread;
    import std.format : format;
    import std.process : environment, execute, Config;
    import std.stdio : writefln, writeln;

    enum modeEnvVar = "SANITIZERS_TSAN_DEMO";
    enum iterations = 100_000;
    /// compiler-rt `tsan_flags.cpp`: `cf.exitcode = 66;` — TSan's default.
    enum tsanDefaultExitCode = 66;

    __gshared int racyCounter;
    shared int atomicCounter;

    /// True when a ThreadSanitizer runtime is linked into this process.
    bool tsanLinked() @trusted
    {
        import core.sys.linux.dlfcn : dlsym, RTLD_DEFAULT;

        return dlsym(RTLD_DEFAULT, "__tsan_init") !is null;
    }

    void runPair(void function() work)
    {
        auto a = new Thread(work);
        auto b = new Thread(work);
        a.start();
        b.start();
        a.join();
        b.join();
    }

    // ---- child side ------------------------------------------------------

    void childRacy()
    {
        runPair(function() {
            foreach (i; 0 .. iterations)
                racyCounter++; // unsynchronized read-modify-write: a data race
        });
        // Printed AFTER both joins: reaching this line under TSan proves the
        // race report did not kill the process (halt_on_error=false default).
        writefln("counter = %s", racyCounter);
    }

    void childAtomic()
    {
        runPair(function() {
            foreach (i; 0 .. iterations)
                atomicOp!"+="(atomicCounter, 1); // __tsan_atomic32_fetch_add
        });
        writefln("counter = %s", atomicCounter);
    }

    // ---- parent side -----------------------------------------------------

    int check(bool condition, string what)
    {
        if (condition)
        {
            writefln("  ok: %s", what);
            return 0;
        }
        writefln("  FAIL: %s", what);
        return 1;
    }

    int run()
    {
        import std.algorithm.searching : canFind;
        import std.file : thisExePath;

        if (const mode = environment.get(modeEnvVar))
        {
            // Child: run the selected demo; TSan (not us) decides the exit
            // code. Both demos exit main normally.
            mode == "racy" ? childRacy() : childAtomic();
            return 0;
        }

        if (!tsanLinked())
        {
            writeln("SKIP: no ThreadSanitizer runtime linked (build with " ~
                "LDC; DMD has no -fsanitize)");
            return 0;
        }

        // Pin the TSan flags this probe's assertions depend on to their
        // documented defaults, so an inherited TSAN_OPTIONS cannot skew them.
        const env = [
            modeEnvVar: "racy",
            "TSAN_OPTIONS": "halt_on_error=0:exitcode=66",
        ];
        int failures;

        writeln("== demo 1+2: racy counter (child) ==");
        const racy = execute([thisExePath], env, Config.newEnv);
        failures += check(racy.status == tsanDefaultExitCode,
            format!"child exit code %s == %s (TSan default exitcode)"(
                racy.status, tsanDefaultExitCode));
        failures += check(
            racy.output.canFind("WARNING: ThreadSanitizer: data race"),
            "report contains 'WARNING: ThreadSanitizer: data race'");
        failures += check(racy.output.canFind("counter = "),
            "child kept running past the report (halt_on_error=false)");

        writeln("== demo 3: core.atomic counter (child) ==");
        const clean = execute([thisExePath],
            [modeEnvVar: "atomic", "TSAN_OPTIONS": ""], Config.newEnv);
        failures += check(clean.status == 0, "atomic child exits 0");
        failures += check(!clean.output.canFind("WARNING: ThreadSanitizer"),
            "no ThreadSanitizer warning for core.atomic increments");
        failures += check(
            clean.output.canFind(format!"counter = %s"(2 * iterations)),
            format!"atomic counter is exact (%s)"(2 * iterations));

        if (failures)
        {
            writefln("FAILED: %s assertion(s)", failures);
            return 1;
        }
        writeln("PASS: TSan caught the race (non-fatally, exit 66) and " ~
            "stayed silent for core.atomic");
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        import std.stdio : writeln;

        writeln("SKIP: this probe exercises Linux TSan runtimes only");
        return 0;
    }
}
