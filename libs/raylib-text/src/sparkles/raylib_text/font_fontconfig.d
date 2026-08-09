/**
The fontconfig half of system font discovery — `fc-match`, `fc-query` and
`fc-scan`, wrapped so a host without them degrades instead of dying.

$(B Why a wrapper at all.) `std.process.execute` reports a missing executable
by $(I throwing) `ProcessException`, not by returning a non-zero status. Every
call site here already branched on `res.status != 0`, so each one read as
though it handled "fontconfig is not installed" — and none of them did. On a
Mac, where fontconfig is normally absent, that turned into an uncaught
exception after the window had already opened. $(LREF fcRun) maps an unrunnable
binary onto $(LREF fcUnavailable), so the existing status checks become true
rather than decorative.

This is not only a macOS concern: a minimal Linux container, a Nix build
sandbox without the fontconfig package, or a stripped BSD hits the same path.

$(B No raylib), the same split `font_discovery.d` and `font_coretext.d` keep —
this module runs subprocesses and parses their output, and knows nothing about
atlases or GL.
*/
module sparkles.raylib_text.font_fontconfig;

import std.typecons : Tuple;

/// The status $(LREF fcRun) reports when the binary could not be run at all,
/// as distinct from fontconfig running and answering "no". Negative so it can
/// never collide with a real exit status.
enum int fcUnavailable = -1;

/// What $(LREF fcRun) returns: the same shape `std.process.execute` produces,
/// so call sites keep reading `res.status` / `res.output`.
alias FcResult = Tuple!(int, "status", string, "output");

/**
Run a fontconfig command, reporting an unrunnable binary as
$(LREF fcUnavailable) rather than throwing.

Every `fc-*` invocation in this package goes through here. A caller that
already tests `status == 0` needs no further change: a host without fontconfig
now takes the same branch as a query that found nothing.
*/
FcResult fcRun(scope const(char[])[] args) @safe nothrow
{
    import std.process : execute;

    try
        return () @trusted {
            auto r = execute(args);
            return FcResult(r.status, r.output);
        }();
    catch (Exception)
        // ProcessException (no such binary), or anything else the spawn path
        // can raise. Either way there is no answer, which is the one thing the
        // caller needs to know.
        return FcResult(fcUnavailable, "");
}

/// `true` when fontconfig is usable on this host. Probed with the cheapest
/// query that touches the whole pipeline, and cached — the answer cannot
/// change within a process, and the probe costs a subprocess.
bool fontconfigAvailable() @safe nothrow
{
    // Not `shared`: like the CoreText table this is consulted from the
    // single-threaded font-setup path, but unlike it the probe is expensive
    // enough to be worth caching, so the double-check is written out.
    static bool probed;
    static bool available;

    if (!probed)
    {
        probed = true;
        available = fcRun(["fc-match", "-f", "%{file}", "monospace"]).status == 0;
    }
    return available;
}

@("font_fontconfig.fcRun.missingBinaryIsAStatusNotAThrow")
@safe nothrow
unittest
{
    // The whole point of the module: this must not escape as an exception.
    const r = fcRun(["definitely-not-a-real-binary-9x7b2", "--version"]);
    assert(r.status == fcUnavailable);
    assert(r.output.length == 0);
}

@("font_fontconfig.fcRun.realBinaryReportsItsStatus")
@safe
unittest
{
    // A binary that DOES exist still reports its own exit status, so the
    // wrapper is transparent to the call sites that branch on it.
    const ok = fcRun(["true"]);
    // `true`/`false` are POSIX shell utilities; skip where they are absent
    // rather than asserting about the host.
    if (ok.status == fcUnavailable)
        return;
    assert(ok.status == 0);
    assert(fcRun(["false"]).status == 1);
}
