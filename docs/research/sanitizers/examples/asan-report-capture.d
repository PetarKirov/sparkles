#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_asan_report_capture"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-fsanitize=address" platform="ldc"
+/
/**
 * Capturing ASan reports from D, two ways — the raw material for per-test
 * attribution in a test runner:
 *
 *   1. `ASAN_OPTIONS=log_path=PREFIX` routes the ENTIRE report to the file
 *      `PREFIX.<pid>` (`ReportFile::ReopenIfNecessary`, compiler-rt
 *      `sanitizer_common/sanitizer_file.cpp:67` — `"%s.%zu"`); the child's
 *      stderr stays silent. The PID suffix disambiguates multiple children,
 *      so one prefix serves a whole process-per-test run.
 *   2. `__asan_set_error_report_callback` registers a D `extern(C)` handler
 *      that receives the FULL report text before the process dies
 *      (compiler-rt `asan_report.cpp:202-221`: the callback runs, then
 *      `Die()`). Caveat proven here: `Die()` exits via `internal__exit`,
 *      which does NOT flush stdio — the handler must write-and-close its own
 *      sink (this probe `fwrite`+`fclose`s a file; a runner would write a
 *      pipe/fd).
 *
 * Both work against GCC 15.2's `libasan.so.8` (the runtime LDC's gcc link
 * fallback actually links on this box) — its `__asan_*`/`__sanitizer_*`
 * control surface is a superset of compiler-rt 18's.
 *
 * Companion to docs/research/sanitizers/asan.md
 *   § "Runtime control and report capture".
 *
 * Run with: dub run --single asan-report-capture.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0
 * (LLVM 18.1.8), GCC 15.2 `libasan.so.8` runtime via LDC's gcc link fallback.
 *
 * Portability: uninstrumented builds (DMD; the dflag is LDC-gated) print a
 * `SKIP:` line and exit 0.
 */
module sanitizers_asan_report_capture;

version (linux)
{
    version (LDC_AddressSanitizer)
    {
        import std.stdio : writefln;

        enum childEnvVar = "SANITIZERS_PROBE_CHILD";
        enum sinkEnvVar = "SANITIZERS_REPORT_SINK";

        extern (C) void __asan_set_error_report_callback(
            void function(const(char)*) callback);

        /// The report callback: runs mid-error-report, so it must not rely on
        /// stdio buffering — write and close explicitly.
        extern (C) void reportSink(const(char)* report)
        {
            import core.stdc.stdio : fclose, fopen, fwrite;
            import core.stdc.stdlib : getenv;
            import core.stdc.string : strlen;

            auto path = getenv(sinkEnvVar);
            if (path is null)
                return;
            auto f = fopen(path, "w");
            if (f is null)
                return;
            fwrite(report, 1, strlen(report), f);
            fclose(f);
        }

        void faultyDemo(bool withCallback)
        {
            import core.stdc.stdio : printf;
            import core.stdc.stdlib : free, malloc;

            if (withCallback)
                __asan_set_error_report_callback(&reportSink);
            int* p = cast(int*) malloc(4 * int.sizeof);
            free(p);
            printf("%d\n", p[0]); // heap-use-after-free
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
            import std.file : exists, mkdirRecurse, readText, rmdirRecurse,
                tempDir;
            import std.path : buildPath;
            import std.process : environment, thisProcessID;

            const mode = environment.get(childEnvVar);
            if (mode == "logpath" || mode == "callback")
            {
                faultyDemo(mode == "callback");
                return 0; // unreachable: ASan halts on the UAF
            }

            import std.conv : to;

            const dir = buildPath(tempDir,
                "sanitizers-report-capture-" ~ thisProcessID.to!string);
            mkdirRecurse(dir);
            scope (exit)
                rmdirRecurse(dir);

            void check(bool cond, string what, string context)
            {
                if (!cond)
                {
                    writefln("FAIL: %s\n--- context ---\n%s", what, context);
                    import core.stdc.stdlib : exit;

                    exit(1);
                }
            }

            // --- Demo 1: log_path routing, PID-suffixed file, silent stderr.
            const prefix = buildPath(dir, "rep");
            string outA;
            import std.file : thisExePath;
            import std.process : pipeProcess, Redirect, wait;

            auto pA = pipeProcess([thisExePath],
                Redirect.stdout | Redirect.stderrToStdout,
                [childEnvVar: "logpath", "ASAN_OPTIONS": "log_path=" ~ prefix]);
            const pidA = pA.pid.processID;
            import std.array : array, join;

            outA = pA.stdout.byLineCopy.array.join("\n");
            const codeA = wait(pA.pid);

            const repFile = prefix ~ "." ~ pidA.to!string;
            check(codeA == 1, "log_path child should still exit 1", outA);
            check(!outA.canFind("AddressSanitizer"),
                "with log_path, the child's stderr/stdout must be silent", outA);
            check(exists(repFile),
                "report file must be named <prefix>.<pid>: " ~ repFile, outA);
            const repText = readText(repFile);
            check(repText.canFind("ERROR: AddressSanitizer: heap-use-after-free")
                && repText.canFind("SUMMARY: AddressSanitizer:"),
                "the whole report must be in the log_path file", repText);

            // --- Demo 2: __asan_set_error_report_callback from D.
            const sink = buildPath(dir, "sink.txt");
            string outB;
            const codeB = spawnChild(
                [childEnvVar: "callback", sinkEnvVar: sink], outB);
            check(codeB == 1, "callback child should still exit 1", outB);
            check(exists(sink), "the D callback should have written its sink",
                outB);
            const sinkText = readText(sink);
            check(sinkText.canFind("ERROR: AddressSanitizer: heap-use-after-free")
                && sinkText.canFind("SUMMARY: AddressSanitizer:"),
                "the callback must receive the FULL report text", sinkText);

            writefln("PASS: log_path routed the report to %s (stderr silent), "
                ~ "and a D __asan_set_error_report_callback captured %d bytes "
                ~ "before Die()", repFile, sinkText.length);
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
