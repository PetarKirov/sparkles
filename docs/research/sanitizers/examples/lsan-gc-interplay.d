#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_lsan_gc_interplay"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-fsanitize=leak" platform="ldc"
+/
/**
 * Standalone LeakSanitizer vs the D garbage collector, four quadrants — the
 * blind spots a `--sanitize=leak` runner mode must document:
 *
 *   1. Q1 `malloc(1001)`, unreachable            -> reported (true leak).
 *   2. Q2 `malloc(2002)` referenced ONLY from a GC array -> reported anyway:
 *      a FALSE POSITIVE. LSan's flood fill follows pointers only through its
 *      own allocator's chunks (compiler-rt `lsan_common.cpp`,
 *      `ClassifyAllChunks`); the D GC's mmap'd pools are not chunks, so
 *      pointers stored in GC memory are invisible to the scan.
 *   3. Q3 `new ubyte[4004]` dropped              -> NOT reported: GC
 *      allocations don't come from the intercepted `malloc`, so true GC
 *      leaks are invisible to LSan.
 *   4. Q4 `malloc(5005)` referenced from a `__gshared` global -> silent:
 *      the root scan does cover D's `.data`/`.bss`.
 *
 * Also demonstrated, correcting a natural assumption: `detect_leaks=0`
 * disables the MANUAL check entry points too (`__lsan_do_leak_check` is
 * gated on the flag, compiler-rt `lsan_common.cpp:1193-1197`) — the
 * composable recipe for per-test checking is `leak_check_at_exit=0` plus
 * repeated `__lsan_do_recoverable_leak_check()`. Standalone LSan exits with
 * code 23 on leaks (`lsan.cpp:61`).
 *
 * No `LDC_LeakSanitizer` version identifier exists (LDC predefines them only
 * for address/memory/thread — `driver/main.cpp:1030-1041` @ v1.41.0), so
 * this probe detects instrumentation at RUNTIME via
 * `dlsym(RTLD_DEFAULT, "__lsan_do_leak_check")`; all `__lsan_*` calls go
 * through the resolved pointers so uninstrumented builds still link.
 *
 * Companion to docs/research/sanitizers/asan.md
 *   § "LeakSanitizer and the D GC".
 *
 * Run with: dub run --single lsan-gc-interplay.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8), GCC 15.2 `liblsan.so.0` runtime via LDC's gcc link fallback.
 *
 * Portability: uninstrumented builds (DMD; the dflag is LDC-gated) find no
 * `__lsan_*` symbols, print a `SKIP:` line and exit 0.
 */
module sanitizers_lsan_gc_interplay;

version (linux)
{
    import std.stdio : writefln;

    enum childEnvVar = "SANITIZERS_PROBE_CHILD";

    alias FatalCheckFn = extern (C) void function();
    alias RecoverableCheckFn = extern (C) int function();

    /// Runtime instrumentation detection: resolve the LSan entry points via
    /// `dlsym` so an uninstrumented binary still links (and SKIPs).
    bool lsanLive(out FatalCheckFn fatal, out RecoverableCheckFn recoverable)
    {
        import core.sys.linux.dlfcn : dlsym, RTLD_DEFAULT;

        fatal = cast(FatalCheckFn) dlsym(RTLD_DEFAULT, "__lsan_do_leak_check");
        recoverable = cast(RecoverableCheckFn) dlsym(RTLD_DEFAULT,
            "__lsan_do_recoverable_leak_check");
        return fatal !is null && recoverable !is null;
    }

    __gshared void*[] gcKeeper; /// keeps the Q2 GC array alive via a data root
    __gshared void* mallocKeeper; /// Q4: a reachable malloc block

    void makeLeaks()
    {
        import core.stdc.stdlib : malloc;

        void* q1 = malloc(1001); // Q1: unreachable malloc -> true leak
        q1 = null;

        auto arr = new void*[4]; // a GC allocation (mmap'd pool)
        arr[0] = malloc(2002); // Q2: only reference lives in GC memory
        gcKeeper = arr;

        auto q3 = new ubyte[4004]; // Q3: dropped GC allocation
        q3 = null;

        mallocKeeper = malloc(5005); // Q4: reachable from .data — no leak
    }

    /// Scrub a few KB of stack so dead pointer copies from `makeLeaks` don't
    /// make Q1/Q2 spuriously reachable to LSan's conservative scan.
    void scrubStack()
    {
        import core.stdc.stdio : printf;

        ubyte[8192] pad = 0;
        printf("", pad.ptr);
    }

    void childDemo(FatalCheckFn fatal, RecoverableCheckFn recoverable)
    {
        import core.stdc.stdio : fprintf, stderr;

        makeLeaks();
        scrubStack();
        const n = recoverable(); // prints a report, does NOT die
        fprintf(stderr, "recoverable returned %d\n", n);
        fatal(); // dies with exit code 23 when leaks were found ...
        fprintf(stderr, "survived both manual checks\n"); // ... else reached
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

        FatalCheckFn fatal;
        RecoverableCheckFn recoverable;
        if (!lsanLive(fatal, recoverable))
        {
            writefln("SKIP: no __lsan_* entry points in this binary "
                ~ "(built without -fsanitize=leak; e.g. a DMD build)");
            return 0;
        }

        if (environment.get(childEnvVar) == "leaks")
        {
            childDemo(fatal, recoverable);
            return 0;
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

        // Child A: default options — quadrants + manual checks.
        string outA;
        const codeA = spawnChild([childEnvVar: "leaks"], outA);
        check(codeA == 23, "leaking child should exit 23 (standalone LSan)",
            outA);
        check(outA.canFind("LeakSanitizer: detected memory leaks"), "child A "
            ~ "should report leaks", outA);
        check(outA.canFind("recoverable returned 1"),
            "__lsan_do_recoverable_leak_check should return 1 and not die",
            outA);
        check(outA.canFind("Direct leak of 1001 byte"),
            "Q1: the unreachable malloc must be reported", outA);
        check(outA.canFind("Direct leak of 2002 byte"),
            "Q2: the GC-referenced malloc is a (known) FALSE POSITIVE — "
            ~ "LSan cannot see D GC pools", outA);
        check(!outA.canFind("4004 byte"),
            "Q3: dropped GC allocations are invisible to LSan", outA);
        check(!outA.canFind("5005 byte"),
            "Q4: a malloc reachable from __gshared data must NOT be reported",
            outA);
        check(!outA.canFind("survived both manual checks"),
            "__lsan_do_leak_check must be fatal when leaks were found", outA);

        // Child B: detect_leaks=0 — the manual entry points become no-ops.
        string outB;
        const codeB = spawnChild(
            [childEnvVar: "leaks", "LSAN_OPTIONS": "detect_leaks=0"], outB);
        check(codeB == 0, "child B should run to completion (exit 0)", outB);
        check(outB.canFind("recoverable returned 0")
            && outB.canFind("survived both manual checks"),
            "detect_leaks=0 must disable the manual checks too", outB);
        check(!outB.canFind("LeakSanitizer"),
            "no report of any kind under detect_leaks=0", outB);

        writefln("PASS: LSan vs the D GC — true malloc leak reported, "
            ~ "GC-referenced malloc falsely reported (blind spot), GC leak "
            ~ "invisible, global-rooted malloc silent; exit 23; "
            ~ "detect_leaks=0 disables manual checks");
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        import std.stdio : writefln;

        writefln("SKIP: this LSan probe is Linux-only");
        return 0;
    }
}
