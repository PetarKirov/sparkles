#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_asan_stack_uar"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
+/
/**
 * AddressSanitizer catching a stack-use-after-return in D, and the runtime
 * flag that gates it: `ASAN_OPTIONS=detect_stack_use_after_return`.
 *
 *   1. Child A (default options): a function stores `&local[3]` into a
 *      `__gshared` pointer and returns; reading it traps as
 *      `stack-use-after-return`. LDC's default
 *      `-fsanitize-address-use-after-return=runtime` emits fake-stack frames
 *      (`__asan_stack_malloc_*`) gated on the runtime global
 *      `__asan_option_detect_stack_use_after_return`, and the runtime default
 *      `detect_stack_use_after_return` is TRUE on Linux (compiler-rt
 *      `asan_flags.inc:52-54` — `SANITIZER_LINUX && !SANITIZER_ANDROID`), so
 *      the catch needs no extra options.
 *   2. Child B (`ASAN_OPTIONS=detect_stack_use_after_return=0`): the same
 *      read silently returns the stale value and exits 0 — the fake stack is
 *      a *runtime* choice with this instrumentation mode.
 *
 * Companion to docs/research/sanitizers/asan.md
 *   § "Stack instrumentation and the fake stack".
 *
 * Run with: dub run --single asan-stack-uar.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8), GCC 15.2 `libasan.so.8` runtime via LDC's gcc link fallback.
 *
 * Portability: uninstrumented builds (DMD; the dflag is LDC-gated) print a
 * `SKIP:` line and exit 0.
 */
module sanitizers_asan_stack_uar;

version (linux)
{
    version (LDC_AddressSanitizer)
    {
        import std.stdio : writefln;

        enum childEnvVar = "SANITIZERS_PROBE_CHILD";

        __gshared int* leaked;

        void victim()
        {
            int[16] local = 7;
            leaked = &local[3];
        }

        /// The faulty demo: read a dead frame's local through a leaked pointer.
        void faultyDemo()
        {
            import core.stdc.stdio : printf;

            victim();
            printf("dead local: %d\n", *leaked); // stack-use-after-return
        }

        int spawnChild(string[string] extraEnv, out string output)
        {
            import std.array : array, join;
            import std.file : thisExePath;
            import std.process : pipeProcess, Redirect, wait;

            auto p = pipeProcess([thisExePath],
                Redirect.stdout | Redirect.stderrToStdout, extraEnv);
            output = p.stdout.byLineCopy.array.join("\n");
            return wait(p.pid);
        }

        int run()
        {
            import std.algorithm.searching : canFind;
            import std.process : environment;

            if (environment.get(childEnvVar) == "uar")
            {
                faultyDemo();
                return 0; // reached only when the fake stack is disabled
            }

            void check(bool cond, string what, string output)
            {
                if (!cond)
                {
                    writefln("FAIL: %s\n--- child output ---\n%s", what, output);
                    import core.stdc.stdlib : exit;

                    exit(1);
                }
            }

            // Child A: defaults — the fake stack is on, the read traps.
            string outA;
            const codeA = spawnChild([childEnvVar: "uar"], outA);
            check(codeA == 1, "child A should die with exitcode=1", outA);
            check(outA.canFind("AddressSanitizer: stack-use-after-return"),
                "child A report should name stack-use-after-return", outA);
            check(outA.canFind("asan-stack-uar.d"),
                "child A report should be self-symbolized to file:line", outA);

            // Child B: same binary, detection turned off at RUNTIME.
            string outB;
            const codeB = spawnChild(
                [childEnvVar: "uar",
                    "ASAN_OPTIONS": "detect_stack_use_after_return=0"], outB);
            check(codeB == 0, "child B should run to completion", outB);
            check(outB.canFind("dead local: 7"),
                "child B should read the stale value silently", outB);

            writefln("PASS: stack-use-after-return caught by default (exit %d) "
                ~ "and silenced by detect_stack_use_after_return=0 (exit %d)",
                codeA, codeB);
            return 0;
        }
    }
}

int main()
{
    version (linux)
    {
        version (LDC_AddressSanitizer)
            return run();
        else
        {
            import std.stdio : writefln;

            writefln("SKIP: built without -fsanitize=address "
                ~ "(LDC_AddressSanitizer not set; e.g. a DMD build)");
            return 0;
        }
    }
    else
    {
        import std.stdio : writefln;

        writefln("SKIP: this ASan probe is Linux-only");
        return 0;
    }
}
