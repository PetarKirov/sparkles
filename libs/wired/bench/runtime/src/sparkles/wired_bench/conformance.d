/**
Conformance of the competitive field.

The perf matrix answers "how fast", and its fingerprint gate proves each
engine agrees with `std.json` on the six benchmark corpora — but those corpora
are all well-formed, so nothing in the timed path asks whether an engine is
fast because it is _lax_. This module closes that gap by running every
compiled engine over the same pinned robustness corpora
$(MREF sparkles,wired,json,conformance) uses for wired itself:

$(LIST
    * nst/JSONTestSuite `test_parsing/` — `y_` must be accepted, `n_` must
        be rejected, `i_` may go either way,
    * nst/JSONTestSuite `test_transform/` — well-formed, implementation-
        defined results; the verdict is free, not crashing is the test,
    * miloyip/nativejson-benchmark — the JSON_checker pass/fail files and
        the roundtrip inputs.
)

Every engine reports a verdict the same way: the adapters signal a rejected
document by throwing, so a caught `Throwable` is a reject and a clean return is
an accept.

$(B The two depth bombs are excluded), and the exclusion is not cosmetic.
`n_structure_100000_opening_arrays.json` (100 000 nested `[`) and
`n_structure_open_array_object.json` (50 000 repetitions of `[{"":`) exhaust
the stack of any recursive-descent parser, and a stack overflow is a signal,
not a `Throwable` — it cannot be caught, so one such engine would abort the
whole matrix before any row printed. `std.json` does exactly that today.
JSONTestSuite's own runner sidesteps this by giving every file its own
process; this matrix is in-process, so it names the two files in
`stackBombs` and scores the other 316 for everyone. Depth limits therefore
want measuring out-of-process — see `bench-baseline.md`. Note that
`sparkles:wired` itself survives both (its reader is iterative, and
$(MREF sparkles,wired,json,conformance) runs the corpus undiluted).

Scores are pinned per engine in `pinnedScores` rather than merely printed.
The dependency versions are locked in `dub.selections.json` and the foreign
shims are nix-pinned, so these numbers are reproducible; a change means an
engine's behaviour moved and wants recording in
$(LINK2 ../../../../docs/specs/wired/bench-baseline.md, bench-baseline.md),
not silent acceptance. Engines that are not compiled into the current
configuration are simply absent from the run.

$(B Why the engine list is a parameter.) This module is deliberately generic
over the engine sequence instead of importing
$(MREF sparkles,wired_bench,engines) itself, and the `@benchmark`-adjacent
unittest that supplies `AllEngines` lives in $(MREF sparkles,wired_bench,runner).
A second module importing the registry adds a second import edge to mir-ion,
and under the `library-inline` parity codegen
(`-enable-cross-module-inlining -linkonce-templates`) that is enough to make
LDC 1.41 die with `Internal compiler error: Type Expression not implemented:
__error` — the same mir-ion/CMI fragility `dub.sdl` already keeps the bench
build type clear of. Bisected to exactly this import: dropping CMI
(`--override-config sparkles:wired/library`) or importing any other engine
module compiles cleanly.
*/
module sparkles.wired_bench.conformance;

version (unittest):

import sparkles.test_runner.skip : skipTest;

/// One engine's verdicts over the pinned corpora. Each `…Ok` counter is the
/// number of files whose verdict matched what the suite requires; `iAccepted`
/// records how many indeterminate files the engine chose to accept, which is
/// a description of its policy rather than a score.
struct ConformanceScore
{
    size_t mustAccept, mustAcceptOk;
    size_t mustReject, mustRejectOk;
    size_t indeterminate, iAccepted;
    size_t transform, transformAccepted;
    size_t roundtrip, roundtripOk;

    /// The headline: the share of prescribed verdicts the engine got right.
    /// `test_transform` and `i_` files are excluded — the suite prescribes no
    /// verdict for either, so counting them would score a policy choice.
    double correctness() const @safe pure nothrow @nogc
    {
        const total = mustAccept + mustReject;
        return total == 0
            ? 0.0
            : 100.0 * (mustAcceptOk + mustRejectOk) / total;
    }

    /// Whether every prescribed verdict was met.
    bool perfect() const @safe pure nothrow @nogc
        => mustAcceptOk == mustAccept && mustRejectOk == mustReject
            && roundtripOk == roundtrip;
}

/// Whether `$WIRED_BENCH_CONFORMANCE_TRACE` is set: names every file on stderr
/// just before it is parsed. The one tool that works when an engine dies by
/// signal — the last line printed is the input that killed it.
private bool tracing() @safe
{
    import std.process : environment;

    return environment.get("WIRED_BENCH_CONFORMANCE_TRACE") !is null;
}

/// Runs `text` through a fresh verdict from `engine`, mapping the adapters'
/// throw-on-reject convention onto a bool. `freeDoc` runs unconditionally so a
/// rejected parse cannot leak into the next file.
private bool accepts(E)(ref E engine, string name, scope const(char)[] text) @system
{
    import std.stdio : stderr;

    import sparkles.wired_bench.traits : hasFreeDoc;

    if (tracing)
    {
        stderr.writefln!"      %s: %s"(E.name, name);
        stderr.flush(); // unbuffered, or a signal death loses the last line
    }

    bool accepted;
    try
    {
        engine.parse(text);
        accepted = true;
    }
    catch (Throwable) // a rejected document; engines signal it by throwing
        accepted = false;

    static if (hasFreeDoc!E)
    {
        try
            engine.freeDoc();
        catch (Throwable)
        {
        }
    }
    return accepted;
}

/// Whether `$WIRED_BENCH_ENGINES` (the comma list the timed matrix also
/// honours) selects `name`; an empty or unset list selects everything.
private bool engineSelected(string name) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.process : environment;

    const list = environment.get("WIRED_BENCH_ENGINES", "");
    return !list.length || list.splitter(',').canFind(name);
}

/// Files excluded from the in-process matrix because they defeat a
/// recursive-descent parser by stack exhaustion rather than by returning a
/// verdict — an uncatchable signal that would abort the run. See the module
/// header; `sparkles:wired`'s own conformance test runs them.
private static immutable string[] stackBombs = [
    "n_structure_100000_opening_arrays.json",
    "n_structure_open_array_object.json",
];

/// Scores one engine over every pinned corpus directory.
private ConformanceScore scoreEngine(E)(string suite, string nativejson) @system
{
    import std.algorithm.searching : canFind, endsWith, startsWith;
    import std.file : dirEntries, read, SpanMode;
    import std.path : baseName;

    import sparkles.wired_bench.traits : hasSetup, hasTeardown;

    ConformanceScore s;
    E engine;
    static if (hasSetup!E)
        engine.setup();
    static if (hasTeardown!E)
        scope (exit) engine.teardown();

    foreach (entry; dirEntries(suite ~ "/test_parsing", "*.json", SpanMode.shallow))
    {
        const name = entry.name.baseName;
        if (stackBombs.canFind(name))
            continue;

        // Byte-oriented: several files are deliberately not valid UTF-8.
        const bytes = cast(const(char)[]) read(entry.name);
        const accepted = accepts(engine, name, bytes);

        switch (name[0])
        {
        case 'y':
            s.mustAccept++;
            s.mustAcceptOk += accepted;
            break;
        case 'n':
            s.mustReject++;
            s.mustRejectOk += !accepted;
            break;
        case 'i':
            s.indeterminate++;
            s.iAccepted += accepted;
            break;
        default:
            break;
        }
    }

    foreach (entry; dirEntries(suite ~ "/test_transform", "*.json", SpanMode.shallow))
    {
        s.transform++;
        s.transformAccepted += accepts(engine, entry.name.baseName,
            cast(const(char)[]) read(entry.name));
    }

    foreach (entry; dirEntries(nativejson ~ "/data/jsonchecker", "*.json",
        SpanMode.shallow))
    {
        const name = entry.name.baseName;
        if (name.endsWith("_EXCLUDE.json"))
            continue; // valid RFC 8259, or an implementation-depth policy case

        const accepted = accepts(engine, name, cast(const(char)[]) read(entry.name));
        if (name.startsWith("pass"))
        {
            s.mustAccept++;
            s.mustAcceptOk += accepted;
        }
        else if (name.startsWith("fail"))
        {
            s.mustReject++;
            s.mustRejectOk += !accepted;
        }
    }

    foreach (entry; dirEntries(nativejson ~ "/data/roundtrip", "*.json",
        SpanMode.shallow))
    {
        s.roundtrip++;
        s.roundtripOk += accepts(engine, entry.name.baseName,
            cast(const(char)[]) read(entry.name));
    }

    return s;
}

/// A pinned per-engine result.
private struct Pinned
{
    string engine;
    ConformanceScore score;
}

/// The pinned field. `wired-native` is the product under test and must be
/// perfect; the rest are recorded as measured, because a competitor's laxness
/// is a finding about that engine, not a defect in this repository. Update an
/// entry only together with a note in `bench-baseline.md`.
/// Measured 2026-08-06 on the pinned corpora, `x86-64-v4` shim preset. The
/// ordering is the report's: D field first, then C/C++, then Rust.
///
/// The headline is that only four engines get every prescribed verdict right —
/// `wired-native`, `yyjson`, `simdjson-dom`, `serde_json`, plus `sonic-rs`
/// once its shim stopped handing it a null pointer. Everything else trades
/// strictness for something: `asdf` accepts 50 of the 217 documents it must
/// reject, `std.json` 35, `mir-ion` 10; `simdjson-ondemand` is the only engine
/// that also *rejects* documents it must accept (8 of 98), which is the lazy
/// navigation model showing through — it never validates what it does not
/// visit. `jsoniopipe` is the one D engine failing a must-accept.
///
/// `i_ accept` is a policy description, not a score: a low number means the
/// engine is strict about the cases RFC 8259 leaves open (lone surrogates,
/// extreme numbers), which is why the strictest engines sit at 4–6 and the
/// laxest at 17–21.
private static immutable Pinned[] pinnedScores = [
    Pinned("std.json", ConformanceScore(98, 98, 217, 182, 35, 14, 22, 18, 27, 27)),
    Pinned("wired-native", ConformanceScore(98, 98, 217, 217, 35, 11, 22, 16, 27, 27)),
    // Same parser as wired-native, compiled as one translation unit, so it
    // must score identically — the opt-in codegen oracle should never change
    // behaviour.
    Pinned("wired-inline", ConformanceScore(98, 98, 217, 217, 35, 11, 22, 16, 27, 27)),
    Pinned("mir-ion", ConformanceScore(98, 98, 217, 207, 35, 18, 22, 16, 27, 27)),
    Pinned("asdf", ConformanceScore(98, 98, 217, 167, 35, 21, 22, 19, 27, 27)),
    Pinned("jsoniopipe", ConformanceScore(98, 97, 217, 191, 35, 12, 22, 16, 27, 27)),
    Pinned("yyjson", ConformanceScore(98, 98, 217, 217, 35, 6, 22, 16, 27, 27)),
    Pinned("simdjson-dom", ConformanceScore(98, 98, 217, 217, 35, 4, 22, 15, 27, 27)),
    Pinned("simdjson-ondemand", ConformanceScore(98, 90, 217, 187, 35, 7, 22, 16, 27, 27)),
    Pinned("rapidjson", ConformanceScore(98, 98, 217, 215, 35, 17, 22, 19, 27, 27)),
    Pinned("serde_json", ConformanceScore(98, 98, 217, 217, 35, 5, 22, 16, 27, 27)),
    Pinned("simd-json", ConformanceScore(98, 98, 217, 216, 35, 7, 22, 16, 27, 27)),
    Pinned("sonic-rs", ConformanceScore(98, 98, 217, 217, 35, 6, 22, 16, 27, 27)),
];

/// The pinned score for `engine`, or `null` when it has none yet.
private immutable(ConformanceScore)* pinnedFor(string engine) @safe pure nothrow @nogc
{
    foreach (ref p; pinnedScores)
        if (p.engine == engine)
            return &p.score;
    return null;
}

/// Scores `Engines` over the pinned corpora, prints the matrix, and returns
/// the number of engines whose result moved from `pinnedScores` (an engine
/// with no pinned entry counts as moved — a new engine must be recorded, not
/// silently admitted). `skipTest`s when the corpora are not on the
/// environment, so the bench's `dub test` works outside the devshell.
///
/// Called from $(MREF sparkles,wired_bench,runner), which owns the engine
/// registry import — see the module header for why that split is load-bearing.
size_t reportFieldConformance(Engines...)() @system
{
    import std.process : environment;
    import std.stdio : stderr;

    const suite = environment.get("JSON_TEST_SUITE");
    const nativejson = environment.get("NATIVEJSON_TEST_SUITE");
    if (suite is null || nativejson is null)
        skipTest("$JSON_TEST_SUITE/$NATIVEJSON_TEST_SUITE not set "
            ~ "(nix devshell exports them)");

    size_t moved;
    stderr.writeln("  conformance of the compiled field "
        ~ "(JSONTestSuite + nativejson-benchmark):");
    stderr.writefln!"    %-18s %7s  %11s  %11s  %9s  %9s"(
        "engine", "correct", "y_ accept", "n_ reject", "i_ accept", "roundtrip");

    static foreach (E; Engines)
    {{
        // Same `$WIRED_BENCH_ENGINES` filter the timed matrix honours, so a
        // single engine can be isolated — the practical way to bisect one that
        // dies by signal, together with `$WIRED_BENCH_CONFORMANCE_TRACE`.
        if (engineSelected(E.name))
        {
        auto s = scoreEngine!E(suite, nativejson);
        stderr.writefln!"    %-18s %6.2f%%  %5s/%-5s  %5s/%-5s  %5s/%-5s  %4s/%-4s"(
            E.name, s.correctness,
            s.mustAcceptOk, s.mustAccept, s.mustRejectOk, s.mustReject,
            s.iAccepted, s.indeterminate, s.roundtripOk, s.roundtrip);

        if (auto pinned = pinnedFor(E.name))
        {
            if (*pinned != s)
            {
                moved++;
                stderr.writefln!"      ^ moved from the pinned score: %s"(*pinned);
            }
        }
        else
        {
            moved++;
            // Emitted paste-ready: adding an engine means adding its row to
            // `pinnedScores`, and the measurement is the only honest source
            // for that row.
            stderr.writefln!"      ^ unpinned; add:  Pinned(\"%s\", %s),"(
                E.name, s);
        }
        }
    }}
    return moved;
}
