/// The D0 bench baseline (`dub test :dsv -- --bench`): parse and sniff over
/// synthesized documents. The `DSN6` scale budgets get their own harness
/// post-CHK; these rows pin the engine's per-row costs from the first
/// commit (the `sparkles:fuzzy` doctrine).
module sparkles.dsv.bench;

version (unittest)  :

import sparkles.test_runner.attributes : benchmark;
import sparkles.dsv.dialect : sniff;
import sparkles.dsv.model : Dialect;
import sparkles.dsv.parse : parseDsv;

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
