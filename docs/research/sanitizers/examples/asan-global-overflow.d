#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_asan_global_overflow"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
+/
/**
 * AddressSanitizer catching a global-buffer-overflow in D.
 *
 *   1. The child reads one element past the end of a module-level
 *      `__gshared int[8]` through `.ptr` (defeating D's own bounds check —
 *      `table[8]` would be caught by the *language* at compile time or as a
 *      `RangeError`). The instrumentation pads globals with redzones (shadow
 *      byte `0xf9`) and registers them via `__asan_register_globals`, so the
 *      one-past-the-end read traps as `global-buffer-overflow` naming the
 *      variable and its size.
 *   2. The parent asserts the report names the defect class and the global's
 *      location, and that the process died with the default exit code 1.
 *
 * Companion to docs/research/sanitizers/asan.md
 *   § "Global instrumentation and redzones".
 *
 * Run with: dub run --single asan-global-overflow.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8), GCC 15.2 `libasan.so.8` runtime via LDC's gcc link fallback.
 *
 * Portability: uninstrumented builds (DMD; the dflag is LDC-gated) print a
 * `SKIP:` line and exit 0.
 */
module sanitizers_asan_global_overflow;

version (linux)
{
    version (LDC_AddressSanitizer)
    {
        import std.stdio : writefln;

        enum childEnvVar = "SANITIZERS_PROBE_CHILD";

        __gshared int[8] table = [1, 2, 3, 4, 5, 6, 7, 8];

        int readAt(size_t i)
        {
            return table.ptr[i]; // .ptr sidesteps D's bounds check
        }

        /// The faulty demo: read one past the end of a global array.
        void faultyDemo()
        {
            import core.stdc.stdio : printf;

            printf("in bounds: %d\n", readAt(7));
            printf("out of bounds: %d\n", readAt(8)); // global-buffer-overflow
        }

        int run()
        {
            import std.algorithm.searching : canFind;
            import std.array : array, join;
            import std.file : thisExePath;
            import std.process : environment, pipeProcess, Redirect, wait;

            if (environment.get(childEnvVar) == "global")
            {
                faultyDemo();
                return 0; // unreachable when ASan is live
            }

            auto p = pipeProcess([thisExePath],
                Redirect.stdout | Redirect.stderrToStdout,
                [childEnvVar: "global"]);
            const output = p.stdout.byLineCopy.array.join("\n");
            const code = wait(p.pid);

            void check(bool cond, string what)
            {
                if (!cond)
                {
                    writefln("FAIL: %s\n--- child output ---\n%s", what, output);
                    import core.stdc.stdlib : exit;

                    exit(1);
                }
            }

            check(code == 1, "child should die with the default exitcode=1");
            check(output.canFind("AddressSanitizer: global-buffer-overflow"),
                "report should name the defect class");
            check(output.canFind("asan-global-overflow.d"),
                "report should locate the faulty read (self-symbolized)");
            check(!output.canFind("out of bounds:"),
                "the overflowing read must not complete");

            writefln("PASS: global-buffer-overflow caught (exit %d), "
                ~ "global redzone trapped the one-past-the-end read", code);
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
