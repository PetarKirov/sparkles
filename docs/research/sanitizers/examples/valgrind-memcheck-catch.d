#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_valgrind_memcheck_catch"
    platforms "linux"
    targetPath "build"
    dflags "-g"
+/
/**
 * Valgrind memcheck catching a heap use-after-free in an UNinstrumented D
 * binary, with a machine-parseable report: the probe re-execs itself under
 * `valgrind --xml=yes --error-exitcode=99`, the child performs the invalid
 * read, and the parent parses the XML error stream and asserts on the error
 * kind, source location, and exit code — the no-recompile pipeline a
 * `--valgrind` runner mode would drive.
 *
 *   1. The child `malloc`s, `free`s, then reads the freed block. No sanitizer
 *      flags are involved: memcheck sees the `free` through its malloc
 *      replacement, marks the block unaddressable (A bits), and flags the
 *      read as `InvalidRead`. This works identically for DMD-compiled
 *      binaries — valgrind is DMD's only memory-error path.
 *   2. `--error-exitcode=99` turns "any error was reported" into exit code 99
 *      (default: the child's own exit code), giving the runner a cheap
 *      error-occurred signal without parsing.
 *   3. `--xml=yes --xml-file=` emits the protocol-4 XML stream; the parent
 *      extracts `<kind>InvalidRead</kind>` and the `<file>`/`<line>` of the
 *      faulting frame — per-finding data a runner can attach to a test.
 *   4. Unlike ASan, the child is not killed at the fault: memcheck reports
 *      and lets the program continue (the child prints its read-after-free
 *      value and exits normally; only `--error-exitcode` marks the run).
 *
 * Companion to docs/research/sanitizers/valgrind.md
 *   § "Runtime control and report capture" (the no-recompile XML + exit-code
 *   pipeline).
 *
 * Run with: dub run --single valgrind-memcheck-catch.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, valgrind 3.26.0
 * (nixpkgs), LDC 1.41.0 and DMD 2.112.1 (both verified — no instrumentation
 * flags, so both compilers exercise the identical path).
 *
 * Portability: hosts without `valgrind` on `PATH` print a `SKIP:` line and
 * exit 0. Linux-only (`platforms "linux"`): nixpkgs valgrind does not build
 * on Apple Silicon.
 */
module sanitizers_valgrind_memcheck_catch;

version (linux)
{
    import std.stdio : writefln;

    enum childEnvVar = "SANITIZERS_PROBE_CHILD";

    /// The faulty demo the child runs: classic heap use-after-free. Memcheck
    /// reports the read but the program continues and exits 0 on its own.
    void faultyDemo()
    {
        import core.stdc.stdio : printf;
        import core.stdc.stdlib : free, malloc;

        int* p = cast(int*) malloc(4 * int.sizeof);
        p[0] = 42;
        free(p);
        printf("read after free: %d\n", p[0]); // memcheck: InvalidRead (size 4)
    }

    int run()
    {
        import std.algorithm.searching : canFind, find;
        import std.file : exists, readText, remove, tempDir;
        import std.format : format;
        import std.path : buildPath;
        import std.process : environment, execute, thisProcessID;

        if (environment.get(childEnvVar) == "valgrind-uaf")
        {
            faultyDemo();
            return 0; // memcheck reports; the child itself exits cleanly
        }

        // Parent: require valgrind on PATH, else SKIP (the devshell carries
        // it; bare `nix run .#ci` hosts may not).
        try
        {
            const probe = execute(["valgrind", "--version"]);
            if (probe.status != 0)
            {
                writefln("SKIP: `valgrind --version` failed (status %d)", probe.status);
                return 0;
            }
            writefln("using %s", probe.output.length ? probe.output : "valgrind");
        }
        catch (Exception e)
        {
            writefln("SKIP: valgrind not found on PATH (%s)", e.msg);
            return 0;
        }

        import std.file : thisExePath;

        const xmlFile = buildPath(tempDir, format!"vg-memcheck-catch-%d.xml"(thisProcessID));
        scope (exit)
            if (xmlFile.exists)
                xmlFile.remove();

        const child = execute(
            [
                "valgrind", "--xml=yes", "--xml-file=" ~ xmlFile,
                "--error-exitcode=99", thisExePath
            ],
            [childEnvVar: "valgrind-uaf"]);

        // 1. --error-exitcode: an error was reported, so valgrind exits 99
        //    even though the child itself exited 0 (memcheck keeps it alive).
        assert(child.status == 99,
            format!"expected exit 99 from --error-exitcode, got %d"(child.status));
        writefln("child exit code: %d (from --error-exitcode; the child itself exited 0)",
            child.status);

        // 2. The child ran PAST the defect — the no-halt contrast to ASan.
        assert(child.output.canFind("read after free: 42"),
            "child should continue past the invalid read");
        writefln("child continued past the defect: %s", "read after free: 42");

        // 3. The XML stream carries the parseable finding.
        const xml = readText(xmlFile);
        assert(xml.canFind("<protocoltool>memcheck</protocoltool>"), "protocol-4 tool tag");
        assert(xml.canFind("<kind>InvalidRead</kind>"),
            "expected <kind>InvalidRead</kind> in the XML error stream");
        assert(xml.canFind("<file>valgrind-memcheck-catch.d</file>"),
            "expected the faulting frame to carry this file's name");
        writefln("XML report: <kind>InvalidRead</kind> at %s",
            "<file>valgrind-memcheck-catch.d</file>");

        writefln("PASS: memcheck caught the use-after-free in an uninstrumented "
            ~ "binary; XML + --error-exitcode form a parseable per-run pipeline");
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

        writefln("SKIP: valgrind probes are Linux-only here");
        return 0;
    }
}
