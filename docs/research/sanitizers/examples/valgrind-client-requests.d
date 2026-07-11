#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_valgrind_client_requests"
    platforms "linux"
    targetPath "build"
    dflags "-g"
    dflags "-i=etc.valgrind"
    debugVersions "VALGRIND"
+/
/**
 * druntime's `etc.valgrind.valgrind` client-request wrappers driving
 * memcheck's A/V bits from D: the probe re-execs itself under
 * `valgrind --xml=yes`, the child marks heap memory `NOACCESS`/`UNDEFINED`
 * through the wrappers and touches it, and the parent asserts memcheck
 * flagged exactly those touches.
 *
 *   1. The recipe that makes `etc.valgrind` usable from user code without
 *      rebuilding druntime: the module body is gated `debug(VALGRIND):`, and
 *      its D wrappers are NOT compiled into the shipped druntime — so the
 *      consumer needs `debugVersions "VALGRIND"` (dub) plus `-i=etc.valgrind`
 *      to compile the wrapper bodies into its own binary. The `extern(C)`
 *      `_d_valgrind_*` implementations (`etc/valgrind/valgrind.c`, holding
 *      the real `VALGRIND_*` request macros) ARE in the shipped druntime of
 *      both LDC 1.41 and DMD 2.112, so the link just works.
 *   2. `makeMemNoAccess` clears the A bits of a live `malloc` block; the
 *      subsequent read is reported as `InvalidRead` — the same mechanics the
 *      druntime GC uses (also `debug(VALGRIND)`-gated, NOT compiled into
 *      shipped druntime) to poison free pages.
 *   3. `makeMemUndefined` on initialized memory clears V bits while keeping
 *      the block addressable; branching on the value is `UninitCondition`.
 *   4. `getVBits` doubles as a `RUNNING_ON_VALGRIND` substitute (druntime
 *      wraps no such request): it returns 0 when not under valgrind and
 *      nonzero success/error codes when the request reaches memcheck.
 *      Outside valgrind every wrapper is a cheap no-op (the magic rotation
 *      preamble executes as plain arithmetic), so the calls are safe to
 *      leave in production code.
 *
 * Companion to docs/research/sanitizers/valgrind.md
 *   § "Client requests: driving the A/V bits from D".
 *
 * Run with: dub run --single valgrind-client-requests.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, valgrind 3.26.0
 * (nixpkgs), LDC 1.41.0 and DMD 2.112.1 (both ship `etc/valgrind/valgrind.d`
 * in their import trees and the `_d_valgrind_*` objects in druntime).
 *
 * Portability: hosts without `valgrind` on `PATH` print a `SKIP:` line and
 * exit 0. Linux-only (`platforms "linux"`).
 */
module sanitizers_valgrind_client_requests;

version (linux)
{
    import std.stdio : writefln;

    enum childEnvVar = "SANITIZERS_PROBE_CHILD";

    /// Child: exercise the wrappers. Under memcheck this produces exactly one
    /// InvalidRead and one UninitCondition; outside valgrind it is a no-op
    /// walk (getVBits reports 0 = not running on valgrind).
    void clientRequestDemo()
    {
        import core.stdc.stdio : printf;
        import core.stdc.stdlib : free, malloc;
        import etc.valgrind.valgrind : getVBits, makeMemDefined, makeMemNoAccess,
            makeMemUndefined;

        int* p = cast(int*) malloc(4 * int.sizeof);
        p[0] = 1;

        // getVBits as the RUNNING_ON_VALGRIND gate: 0 = not under valgrind.
        ubyte[4] vbits;
        const onValgrind = getVBits(p[0 .. 1], vbits[]);
        printf("getVBits => %u (0 means not under valgrind)\n", onValgrind);

        // A-bit poisoning: reading a live allocation marked NOACCESS.
        makeMemNoAccess(p[0 .. 4]);
        printf("noaccess read: %d\n", p[0]); // memcheck: InvalidRead
        makeMemDefined(p[0 .. 4]); // restore so free() itself stays clean

        // V-bit poisoning: branching on a value marked UNDEFINED.
        p[1] = 7;
        makeMemUndefined(p[1 .. 2]);
        if (p[1] > 3) // memcheck: UninitCondition
            printf("branch taken\n");

        free(p);
    }

    int run()
    {
        import std.algorithm.searching : canFind;
        import std.file : exists, readText, remove, tempDir, thisExePath;
        import std.format : format;
        import std.path : buildPath;
        import std.process : environment, execute, thisProcessID;

        if (environment.get(childEnvVar) == "valgrind-clientreq")
        {
            clientRequestDemo();
            return 0;
        }

        // Sanity outside valgrind first: all requests must be no-ops.
        clientRequestDemo();
        writefln("outside valgrind: wrappers are no-ops (no crash, getVBits 0)");

        try
        {
            const probe = execute(["valgrind", "--version"]);
            if (probe.status != 0)
            {
                writefln("SKIP: `valgrind --version` failed (status %d)", probe.status);
                return 0;
            }
        }
        catch (Exception e)
        {
            writefln("SKIP: valgrind not found on PATH (%s)", e.msg);
            return 0;
        }

        const xmlFile = buildPath(tempDir, format!"vg-clientreq-%d.xml"(thisProcessID));
        scope (exit)
            if (xmlFile.exists)
                xmlFile.remove();

        const child = execute(
            [
                "valgrind", "--xml=yes", "--xml-file=" ~ xmlFile,
                "--error-exitcode=99", thisExePath
            ],
            [childEnvVar: "valgrind-clientreq"]);

        assert(child.status == 99,
            format!"expected exit 99 from --error-exitcode, got %d"(child.status));

        // The child's own view: the request reached memcheck (getVBits != 0).
        assert(!child.output.canFind("getVBits => 0 "),
            "child under valgrind should see getVBits != 0");
        writefln("child under valgrind: getVBits nonzero (request reached memcheck)");

        const xml = readText(xmlFile);
        assert(xml.canFind("<kind>InvalidRead</kind>"),
            "makeMemNoAccess + read should yield InvalidRead");
        assert(xml.canFind("<kind>UninitCondition</kind>"),
            "makeMemUndefined + branch should yield UninitCondition");
        writefln("XML report: InvalidRead (A bits) + UninitCondition (V bits)");

        writefln("PASS: etc.valgrind client requests drove memcheck's A/V bits "
            ~ "from D user code against the SHIPPED (unrebuilt) druntime");
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
