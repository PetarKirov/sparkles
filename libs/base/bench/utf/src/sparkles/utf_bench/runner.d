module sparkles.utf_bench.runner;

import expected : err, ok;
import std.conv : to;
import std.process : environment;
import std.algorithm.iteration : splitter;
import std.algorithm.searching : canFind, startsWith;
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;
import sparkles.utf_bench.corpus : Corpus, corpora, DisplayCorpus, displayCorpora;
import sparkles.utf_bench.engines;
import sparkles.utf_bench.reference : Conversion, checksum;

private bool enabled(string variable, string name)
{
    const filter = environment.get(variable, "");
    return filter.length == 0 || filter.splitter(',').canFind(name);
}

private bool selected(string name)
{
    const filter = environment.get("UTF_BENCH_CORPORA", "");
    if (!filter.length) return true;
    foreach (prefix; filter.splitter(','))
        if (name.startsWith(prefix)) return true;
    return false;
}

private enum Operation { offset, boolean, to16, to8 }

// All retained callbacks bind a heap object's methods: no deferred stack delegates,
// loop-variable capture, or DIP1000 closure-lifetime dependence.
private final class UtfRow(E, Operation op)
{
    Corpus corpus;
    wchar[] output16;
    char[] output8;
    size_t payloadCapacity;
    size_t batch;
    size_t offset;
    bool valid;
    Conversion converted;
    ulong expectedChecksum;
    string implementation;
    string revision;

    this(Corpus input)
    {
        corpus = input;
        implementation = E.implementation(); // runtime dispatch warmup, outside timing
        revision = E.revision();
        static if (op == Operation.to8)
        {
            payloadCapacity = corpus.wide.length * 3;
            output8 = new char[payloadCapacity + 8];
            output8[] = '\xA5';
            expectedChecksum = checksum(corpus.text);
        }
        else static if (op == Operation.to16)
        {
            payloadCapacity = corpus.text.length;
            output16 = new wchar[payloadCapacity + 8];
            output16[] = cast(wchar) 0xA55A;
            expectedChecksum = checksum(corpus.wide);
        }
        const bytes = op == Operation.to8 ? corpus.wide.length * 2 : corpus.text.length;
        // benchCase timestamps every call. Batch tiny operations to avoid measuring
        // mainly clock overhead; report B/s for the entire explicitly labelled batch.
        batch = bytes < 256 ? 64 : 1;
    }

    void timed()
    {
        foreach (_; 0 .. batch)
        {
            static if (op == Operation.offset)
            {
                offset = E.invalid(blackBox(corpus.text));
                blackBox(offset);
            }
            else static if (op == Operation.boolean)
            {
                valid = E.valid(blackBox(corpus.text));
                blackBox(valid);
            }
            else static if (op == Operation.to16)
            {
                converted = E.convert16(blackBox(corpus.text), blackBox(output16[0 .. payloadCapacity]));
                blackBox(converted);
                blackBox(output16);
            }
            else
            {
                converted = E.convert8(blackBox(corpus.wide), blackBox(output8[0 .. payloadCapacity]));
                blackBox(converted);
                blackBox(output8);
            }
        }
    }

    private string mismatch()
    {
        static if (op == Operation.offset)
        {
            if (offset != corpus.invalid8) return "first invalid sequence offset differs";
        }
        else static if (op == Operation.boolean)
        {
            if (valid != corpus.valid8) return "validity differs";
        }
        else
        {
            enum toWide = op == Operation.to16;
            const expectedValid = toWide ? corpus.valid8 : corpus.valid16;
            if (converted.valid != expectedValid) return "conversion validity differs";
            const expectedCount = expectedValid
                ? (toWide ? corpus.wide.length : corpus.text.length)
                : (toWide ? corpus.invalid8 : corpus.invalid16);
            if (converted.count != expectedCount) return "conversion output length / error offset differs";
            static if (toWide)
            {
                if (expectedValid)
                {
                    if (output16[0 .. converted.count] != corpus.wide) return "full UTF16 output differs";
                    if (checksum(output16[0 .. converted.count]) != expectedChecksum) return "UTF16 checksum differs";
                }
                foreach (value; output16[payloadCapacity .. $])
                    if (value != 0xA55A) return "UTF16 output guard overwritten";
                static if (E.contract == "bounded-fail-before-write")
                    if (!expectedValid)
                        foreach (value; output16)
                            if (value != 0xA55A) return "failed conversion wrote UTF16 destination";
            }
            else
            {
                if (expectedValid)
                {
                    if (output8[0 .. converted.count] != corpus.text) return "full UTF8 output differs";
                    if (checksum(output8[0 .. converted.count]) != expectedChecksum) return "UTF8 checksum differs";
                }
                foreach (value; output8[payloadCapacity .. $])
                    if (value != '\xA5') return "UTF8 output guard overwritten";
                static if (E.contract == "bounded-fail-before-write")
                    if (!expectedValid)
                        foreach (value; output8)
                            if (value != '\xA5') return "failed conversion wrote UTF8 destination";
            }
        }
        return null;
    }

    auto after()
    {
        const error = mismatch();
        return error.length ? err!bool(error ~ ": " ~ E.name ~ " / " ~ corpus.name) : ok!string(true);
    }

    void registerCase()
    {
        const bytes = op == Operation.to8 ? corpus.wide.length * 2 : corpus.text.length;
        benchCase(name: E.name, timed: &timed, after: &after,
            metrics: [Metric(unit: Unit("B"), amount: double(bytes * batch), mode: Metric.Mode.rate)],
            labels: ["corpus": corpus.name, "operation": op.to!string,
                "contract": op == Operation.offset ? "first-invalid-sequence-byte" :
                    op == Operation.boolean ? "bool-only" : E.contract,
                "implementation": implementation, "revision": revision,
                "ffi": E.name == "simdutf" || E.name == "simdutf8" ? "extern-C" : "native-D",
                "input-bytes": bytes.to!string, "batch": batch.to!string]);
    }

    void sweep()
    {
        timed();
        const result = after();
        if (result.hasError) throw new Exception(result.error);
    }
}

private bool applies(Operation op, Corpus c)
{
    const wideOnly = c.name.startsWith("invalid16/");
    return op == Operation.to8 ? c.valid8 || wideOnly : !wideOnly;
}

private void matrix(Operation op)(bool measure)
{
    foreach (c; corpora())
        if (selected(c.name) && applies(op, c))
        {
            static foreach (E; AliasSeq!(Scalar, Sparkles))
                if (enabled("UTF_BENCH_ENGINES", E.name))
                {
                    auto row = new UtfRow!(E, op)(c);
                    if (measure) row.registerCase(); else row.sweep();
                }
            version (UtfBenchSimdutf)
                if (enabled("UTF_BENCH_ENGINES", Simdutf.name))
                {
                    auto row = new UtfRow!(Simdutf, op)(c);
                    if (measure) row.registerCase(); else row.sweep();
                }
            version (UtfBenchRust)
                static if (op == Operation.offset || op == Operation.boolean)
                    if (enabled("UTF_BENCH_ENGINES", Simdutf8.name))
                    {
                        auto row = new UtfRow!(Simdutf8, op)(c);
                        if (measure) row.registerCase(); else row.sweep();
                    }
        }
}

import std.meta : AliasSeq;

@("utf.offset") @benchmark @system unittest { matrix!(Operation.offset)(true); }
@("utf.boolean") @benchmark @system unittest { matrix!(Operation.boolean)(true); }
@("utf.to16") @benchmark @system unittest { matrix!(Operation.to16)(true); }
@("utf.to8") @benchmark @system unittest { matrix!(Operation.to8)(true); }

// Explicit non-benchmark correctness command: never times and never produces a
// misleading benchmark baseline. Includes error and output-guard verification.
@("utf.correctness") @system unittest
{
    matrix!(Operation.offset)(false);
    matrix!(Operation.boolean)(false);
    matrix!(Operation.to16)(false);
    matrix!(Operation.to8)(false);
    displayMatrix(false);
}

private final class DisplayRow(bool rust, bool segmentation)
{
    DisplayCorpus corpus;
    size_t[] boundaries;
    size_t result;
    size_t batch;

    this(DisplayCorpus input)
    {
        corpus = input;
        boundaries = new size_t[corpus.text.length + 8];
        boundaries[] = size_t.max;
        batch = corpus.text.length < 256 ? 64 : 1;
    }

    void timed()
    {
        import sparkles.base.text.grapheme : byGraphemeCluster, visibleWidth;
        foreach (_; 0 .. batch)
        {
            static if (rust)
            {
                version (UtfBenchRust)
                {
                    static if (segmentation)
                        result = utf_bench_xutf_boundaries(blackBox(corpus.text).ptr,
                            corpus.text.length, blackBox(boundaries).ptr, corpus.text.length);
                    else
                        result = utf_bench_xutf_width(blackBox(corpus.text).ptr, corpus.text.length);
                }
            }
            else static if (segmentation)
            {
                size_t end;
                result = 0;
                foreach (cluster; byGraphemeCluster(blackBox(corpus.text)))
                {
                    end += cluster.slice.length;
                    boundaries[result++] = end;
                }
            }
            else result = visibleWidth(blackBox(corpus.text));
            blackBox(result);
            static if (segmentation) blackBox(boundaries);
        }
    }

    auto after()
    {
        string error;
        static if (segmentation)
        {
            if (result != corpus.boundaries.length) error = "cluster count differs";
            else if (boundaries[0 .. result] != corpus.boundaries) error = "full cluster boundaries differ";
            foreach (value; boundaries[corpus.text.length .. $])
                if (value != size_t.max) error = "cluster output guard overwritten";
        }
        else if (result != corpus.width) error = "display width differs";
        return error.length ? err!bool(error ~ ": " ~ corpus.name) : ok!string(true);
    }

    void registerCase()
    {
        benchCase(name: rust ? "xutf" : "sparkles", timed: &timed, after: &after,
            metrics: [Metric(unit: Unit("B"), amount: double(corpus.text.length * batch), mode: Metric.Mode.rate)],
            labels: ["corpus": corpus.name, "operation": segmentation ? "cluster-boundaries" : "visible-width",
                "contract": "matched-printable-fixtures-no-ANSI",
                "implementation": rust ? "rust-portable-simd" : "native-d-phobos-segmentation",
                "revision": rust ? "9bb347af041369a68a4effd1ca85c6d2f9b4e17b" : "worktree-source",
                "ffi": rust ? "extern-C" : "native-D", "batch": batch.to!string]);
    }

    void sweep()
    {
        timed();
        const checked = after();
        if (checked.hasError) throw new Exception(checked.error);
    }
}

private void displayMatrix(bool measure)
{
    foreach (c; displayCorpora())
        if (selected(c.name))
            static foreach (segmentation; [false, true])
            {
                if (enabled("UTF_BENCH_ENGINES", "sparkles"))
                {
                    auto row = new DisplayRow!(false, segmentation)(c);
                    if (measure) row.registerCase(); else row.sweep();
                }
                version (UtfBenchRust)
                    if (enabled("UTF_BENCH_ENGINES", "xutf"))
                    {
                        auto row = new DisplayRow!(true, segmentation)(c);
                        if (measure) row.registerCase(); else row.sweep();
                    }
            }
}

@("utf.display") @benchmark @system unittest { displayMatrix(true); }
