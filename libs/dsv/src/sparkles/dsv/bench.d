/// The D0 bench baseline (`dub test :dsv -- --bench`): parse and sniff over
/// synthesized documents. The `DSN6` scale budgets get their own harness
/// post-CHK; these rows pin the engine's per-row costs from the first
/// commit (the `sparkles:fuzzy` doctrine).
module sparkles.dsv.bench;

version (unittest)  :

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.test_runner.attributes : benchmark, workload;
import sparkles.dsv.dialect : sniff, sniffMaxRecords;
import sparkles.dsv.model : ColumnType, Dialect, DsvDoc, inferColumnTypes;
import sparkles.dsv.parse : parseDsv;
import sparkles.dsv.project : applyProjection, ProjectionSpec, SortKey;

/// A five-column document: integer · text · quoted-decimal/float mix ·
/// bool · date. Quotes on every third row keep the decode path honest.
private string makeCsv(size_t rows) @safe
{
    import std.array : appender;
    import std.conv : to;

    auto a = appender!string;
    a ~= "id,name,price,flag,when\n";
    foreach (i; 0 .. rows)
    {
        a ~= i.to!string;
        a ~= ",item-";
        a ~= (i % 97).to!string;
        a ~= i % 3 == 0 ? ",\"1,5\"" : ",2.25";
        a ~= i % 2 == 0 ? ",true" : ",false";
        a ~= ",2026-08-18\n";
    }
    return a[];
}

@("dsv.bench.parse")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    const csv1k = makeCsv(1_000);
    const csv10k = makeCsv(10_000);
    benchIter({ blackBox(parseDsv(blackBox(csv1k), Dialect(','))); },
        ["op": "parse", "rows": "1k"]);
    benchIter({ blackBox(parseDsv(blackBox(csv10k), Dialect(','))); },
        ["op": "parse", "rows": "10k"]);
}

@("dsv.bench.sniff")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    // The recommended sample shape: ~100 records (`sniffMaxRecords`).
    const sample = makeCsv(100);
    benchIter({ blackBox(sniff(blackBox(sample))); },
        ["op": "sniff", "rows": "100"]);
}

// ── `DSN6` scale: the 100 MB / 1M-row target ───────────────────────────────
//
// The budgets the spec names, measured on a corpus of that size rather than
// extrapolated from a small one. `@workload` rather than `@benchmark`: one
// pass, measured as a window, and skipped entirely outside `--bench` — a
// 73 MB corpus is not something an ordinary `dub test :dsv` should build.
//
//   dub test :dsv -b bench -- --bench -i dsv.scale
//
// A `files.csv`-shaped table: a path column (text), integer counts, an
// extension, an author and a date — the mix a real data browser sorts by.

/// The scale corpus, built once and shared by every workload below.
private final class ScaleCorpus
{
    string src;
    typeof(parseDsv("", Dialect.init)) parsed;
    DsvDoc doc;
    SmallBuffer!(ColumnType, 16) types;

    this() @safe
    {
        import std.array : appender;
        import std.format : formattedWrite;

        static immutable exts = ["d", "md", "nix", "sdl", "json", "c"];
        static immutable dirs = ["libs/base", "libs/ui", "apps/hue",
            "libs/event-horizon", "docs/research/ui-layout", "nix/packages"];
        auto w = appender!string;
        w.reserve(scaleRows * 110);
        w.put("path,lines,bytes,ext,author,modified,commits,churn\n");
        foreach (i; 0 .. scaleRows)
            w.formattedWrite!"%s/module_%s.%s,%s,%s,%s,Petar Kirov,2026-%02d-%02d,%s,%s\n"(
                dirs[i % dirs.length], i, exts[i % exts.length],
                40 + i % 900, 1024 + i * 7, exts[i % exts.length],
                1 + i % 12, 1 + i % 28, i % 50, i % 3000);
        src = w[];

        parsed = parseDsv(src, Dialect(','));
        doc = parsed.value;
        doc.hasHeader = true;
        inferColumnTypes(doc, sniffMaxRecords, types);
    }
}

/// `DSN6`'s row count. ~73 MB at this shape.
private enum size_t scaleRows = 1_000_000;

/// The whole-file parse — `DSN2`'s subject, and the one inherently
/// sequential pass. Budget: it must fit inside a 300 ms first paint, which
/// today it does only because nothing else on that path is expensive.
@("dsv.scale.parse-1M")
@workload @system
unittest
{
    import sparkles.test_runner.workload : workloadWindow;

    auto fx = new ScaleCorpus;
    workloadWindow("parse", {
        auto r = parseDsv(fx.src, Dialect(','));
        assert(!r.hasError);
    });
}

/// Filtering alone (no sort) — `DSN6`'s "filter keystroke-to-first-results
/// ≤ 100 ms".
@("dsv.scale.project-1M")
@workload @system
unittest
{
    import sparkles.test_runner.workload : workloadWindow;

    auto fx = new ScaleCorpus;
    workloadWindow("project", {
        SmallBuffer!(uint, 64) perm;
        applyProjection(fx.doc, fx.types[], ProjectionSpec.init, perm);
        assert(perm.length == scaleRows);
    });
}

/// `DSN6`'s "sort of 1M indexed rows ≤ 1 s", on both a numeric key (where
/// the extracted key is a `double`) and a text key (where the comparison
/// itself is the remaining work).
@("dsv.scale.sort-1M")
@workload @system
unittest
{
    import sparkles.test_runner.workload : workloadWindow;

    auto fx = new ScaleCorpus;
    foreach (k; [
        ScaleSort("integer-key", 1),
        ScaleSort("text-key", 0),
    ])
    {
        ProjectionSpec spec;
        spec.sortKeys = [SortKey(column: k.column)];
        workloadWindow(k.name, {
            SmallBuffer!(uint, 64) perm;
            applyProjection(fx.doc, fx.types[], spec, perm);
            assert(perm.length == scaleRows);
        });
    }
}

private struct ScaleSort { string name; uint column; }
