#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_asan_heap_uaf"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
+/
/**
 * AddressSanitizer catching a heap use-after-free in D, via the child-process
 * pattern: the probe re-execs itself with `SANITIZERS_PROBE_CHILD=uaf`, the
 * child dies with the ASan report, and the parent asserts on the report text
 * and exit code, so CI stays green while the catch is really demonstrated.
 *
 *   1. The child `malloc`s, `free`s, then reads the freed block; ASan's
 *      quarantine keeps the block poisoned (shadow byte `0xfd`), so the read
 *      traps as `heap-use-after-free` with allocation *and* deallocation
 *      stacks.
 *   2. The parent asserts the default fatal behavior: exit code 1 (the
 *      `exitcode` common flag's default) after one report.
 *   3. The report carries `file:line` for the D frames with NO
 *      `llvm-symbolizer` on `PATH`: on this toolchain LDC's gcc link fallback
 *      links GCC 15.2's `libasan.so.8`, which self-symbolizes via its bundled
 *      libbacktrace (the `__asan_backtrace_*` symbols).
 *
 * Companion to docs/research/sanitizers/asan.md
 *   § "Heap poisoning, redzones, and the quarantine".
 *
 * Run with: dub run --single asan-heap-uaf.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8 instrumentation), GCC 15.2 `libasan.so.8` runtime via LDC's
 * gcc link fallback (`driver/linker-gcc.cpp` — no compiler-rt shipped by
 * nixpkgs LDC).
 *
 * Portability: builds without `-fsanitize=address` (e.g. DMD — the flag is
 * LDC-gated above and the `LDC_AddressSanitizer` version identifier is then
 * absent) print a `SKIP:` line and exit 0.
 */
module sanitizers_asan_heap_uaf;

version (linux)
{
    version (LDC_AddressSanitizer)
    {
        import std.stdio : writefln;

        enum childEnvVar = "SANITIZERS_PROBE_CHILD";

        /// The faulty demo the child runs: classic heap use-after-free.
        void faultyDemo()
        {
            import core.stdc.stdio : printf;
            import core.stdc.stdlib : free, malloc;

            int* p = cast(int*) malloc(4 * int.sizeof);
            p[0] = 42;
            free(p);
            printf("read after free: %d\n", p[0]); // dies here: heap-use-after-free
        }

        int run()
        {
            import std.algorithm.searching : canFind;
            import std.array : array, join;
            import std.file : thisExePath;
            import std.process : environment, pipeProcess, Redirect, wait;

            if (environment.get(childEnvVar) == "uaf")
            {
                faultyDemo();
                return 0; // unreachable when ASan is live
            }

            auto p = pipeProcess([thisExePath],
                Redirect.stdout | Redirect.stderrToStdout,
                [childEnvVar: "uaf"]);
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
            check(output.canFind("AddressSanitizer: heap-use-after-free"),
                "report should name the defect class");
            check(output.canFind("freed by thread")
                && output.canFind("previously allocated by thread"),
                "report should carry both the free and the alloc stacks");
            check(output.canFind("asan-heap-uaf.d"),
                "GCC libasan should self-symbolize D frames to file:line "
                ~ "without llvm-symbolizer");
            check(!output.canFind("read after free:"),
                "the faulty read must not complete (halt_on_error=1 default)");

            writefln("PASS: heap-use-after-free caught (exit %d), alloc+free "
                ~ "stacks present, self-symbolized to file:line", code);
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
