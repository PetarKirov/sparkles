#!/usr/bin/env dub
/+ dub.sdl:
    name "sanitizers_valgrind_attribution"
    platforms "linux"
    targetPath "build"
    dflags "-g"
+/
/**
 * Per-test attribution of valgrind findings via `VALGRIND_PRINTF` markers in
 * the `--xml=yes` stream: the child emits a marker client request before each
 * "test", each test commits a distinct memory error, and the parent proves the
 * XML stream interleaves `<clientmsg>` records IN ORDER with `<error>`
 * records — so a runner can attribute every error between marker N and marker
 * N+1 to test N. This decides the `--valgrind` mode's attribution design.
 *
 *   1. The client-request mechanism, hand-rolled in ~20 lines of D inline
 *      asm: valgrind's amd64 magic preamble is `rol rdi` by 3, 13, 61, 51 (a
 *      net no-op — 128 bits of rotation) followed by `xchg rbx,rbx`; args go
 *      through RAX, the result through RDX (`include/valgrind.h.in`). Outside
 *      valgrind the sequence executes as plain arithmetic and the default
 *      value flows through — the same trick `etc.valgrind`'s C side uses.
 *   2. `VG_USERREQ__PRINTF_VALIST_BY_REF` (0x1403) takes a format pointer and
 *      a `va_list*`; on linux-x86_64 D's `va_list` is already the pointer to
 *      the `__va_list_tag` record, so it is passed as-is (NOT `&ap` — the
 *      deprecated 0x1401 request aborts on amd64 where
 *      `sizeof(va_list) != sizeof(UWord)`).
 *   3. `RUNNING_ON_VALGRIND` (0x1001) gates the child: outside valgrind the
 *      markers would vanish, so the demo only asserts under the tool.
 *   4. The parent asserts the stream shape: clientmsg("test=1") precedes
 *      error(InvalidRead), which precedes clientmsg("test=2"), which precedes
 *      error(InvalidWrite). Caveat a runner must own: valgrind DEDUPLICATES
 *      errors by context — a repeat of an already-seen error in a later test
 *      emits no new `<error>` record (only end-of-run `<errorcounts>`), so
 *      marker-window attribution sees only each context's FIRST occurrence.
 *
 * Companion to docs/research/sanitizers/valgrind.md
 *   § "Runner integration semantics" (per-test attribution: markers in the XML
 *   stream).
 *
 * Run with: dub run --single valgrind-attribution.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX, valgrind 3.26.0
 * (nixpkgs), LDC 1.41.0 and DMD 2.112.1 (both compilers' `D_InlineAsm_X86_64`
 * verified against valgrind 3.26.0's request dispatch).
 *
 * Portability: hosts without `valgrind` on `PATH`, and ISAs without
 * `D_InlineAsm_X86_64`, print a `SKIP:` line and exit 0. Linux-only
 * (`platforms "linux"`).
 */
module sanitizers_valgrind_attribution;

version (linux)
{
    import std.stdio : writefln;

    enum childEnvVar = "SANITIZERS_PROBE_CHILD";

    enum : ulong
    {
        VG_USERREQ__RUNNING_ON_VALGRIND = 0x1001,
        VG_USERREQ__PRINTF_VALIST_BY_REF = 0x1403,
    }

    /// valgrind's client-request trap, amd64 encoding: the rotation preamble
    /// plus `xchg rbx,rbx`. Args pointer in RAX, default + result in RDX.
    /// A no-op returning `defaultResult` when not running under valgrind.
    ulong valgrindClientRequest(ulong defaultResult, ulong request,
        ulong a1 = 0, ulong a2 = 0, ulong a3 = 0, ulong a4 = 0, ulong a5 = 0)
        @system nothrow @nogc
    {
        version (D_InlineAsm_X86_64)
        {
            ulong[6] args = [request, a1, a2, a3, a4, a5];
            ulong result = defaultResult;
            auto p = args.ptr;
            asm nothrow @nogc
            {
                mov RAX, p;
                mov RDX, result;
                rol RDI, 3;
                rol RDI, 13;
                rol RDI, 61;
                rol RDI, 51;
                xchg RBX, RBX;
                mov result, RDX;
            }
            return result;
        }
        else
            return defaultResult;
    }

    /// `VALGRIND_PRINTF`: emits a `<clientmsg>` record into the XML stream
    /// (a plain user message in text mode). Returns the byte count printed.
    extern (C) int vgPrintf(scope const(char)* format, ...) @system
    {
        import core.stdc.stdarg : va_end, va_list, va_start;

        va_list ap;
        va_start(ap, format);
        scope (exit)
            va_end(ap);
        // On linux-x86_64 `va_list` is `__va_list_tag*` — already the address
        // the by-ref request wants.
        return cast(int) valgrindClientRequest(0, VG_USERREQ__PRINTF_VALIST_BY_REF,
            cast(ulong) format, cast(ulong) ap);
    }

    /// Child: two "tests", each announced by a marker, each committing a
    /// distinct memory error (distinct kind AND site, so dedup can't fold).
    void markedTestsDemo()
    {
        import core.stdc.stdio : printf;
        import core.stdc.stdlib : free, malloc;

        vgPrintf("MARKER test=%d name=%s", 1, "first.invalid.read".ptr);
        int* p = cast(int*) malloc(4 * int.sizeof);
        p[0] = 1;
        free(p);
        printf("uaf value: %d\n", p[0]); // test 1's finding: InvalidRead

        vgPrintf("MARKER test=%d name=%s", 2, "second.invalid.write".ptr);
        char* q = cast(char*) malloc(8);
        q[9] = 'x'; // test 2's finding: InvalidWrite (heap overflow)
        free(q);
    }

    int run()
    {
        import std.algorithm.searching : canFind;
        import std.file : exists, readText, remove, tempDir, thisExePath;
        import std.format : format;
        import std.path : buildPath;
        import std.process : environment, execute, thisProcessID;
        import std.string : indexOf;

        version (D_InlineAsm_X86_64)
        {
        }
        else
        {
            writefln("SKIP: the hand-rolled client request needs x86_64 inline asm");
            return 0;
        }

        if (environment.get(childEnvVar) == "valgrind-markers")
        {
            if (valgrindClientRequest(0, VG_USERREQ__RUNNING_ON_VALGRIND) == 0)
            {
                writefln("child not under valgrind?");
                return 1;
            }
            markedTestsDemo();
            return 0;
        }

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

        const xmlFile = buildPath(tempDir, format!"vg-attribution-%d.xml"(thisProcessID));
        scope (exit)
            if (xmlFile.exists)
                xmlFile.remove();

        const child = execute(
            [
                "valgrind", "--xml=yes", "--xml-file=" ~ xmlFile,
                "--error-exitcode=99", thisExePath
            ],
            [childEnvVar: "valgrind-markers"]);

        assert(child.status == 99,
            format!"expected exit 99 from --error-exitcode, got %d"(child.status));

        const xml = readText(xmlFile);

        // The four records, in stream order: marker 1, its error, marker 2,
        // its error. `indexOf` positions prove the interleaving.
        const m1 = xml.indexOf("MARKER test=1 name=first.invalid.read");
        const e1 = xml.indexOf("<kind>InvalidRead</kind>");
        const m2 = xml.indexOf("MARKER test=2 name=second.invalid.write");
        const e2 = xml.indexOf("<kind>InvalidWrite</kind>");

        assert(m1 >= 0, "marker 1 missing — <clientmsg> not in the XML stream?");
        assert(e1 >= 0, "InvalidRead error missing");
        assert(m2 >= 0, "marker 2 missing");
        assert(e2 >= 0, "InvalidWrite error missing");
        assert(m1 < e1 && e1 < m2 && m2 < e2,
            format!"stream order violated: m1=%d e1=%d m2=%d e2=%d"(m1, e1, m2, e2));

        writefln("stream order: clientmsg(test=1) @%d < error(InvalidRead) @%d "
            ~ "< clientmsg(test=2) @%d < error(InvalidWrite) @%d", m1, e1, m2, e2);
        writefln("PASS: VALGRIND_PRINTF markers segment one process's XML error "
            ~ "stream by test — marker-window attribution is viable");
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
