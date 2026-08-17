/**
M0 latency measurements — the numbers behind the decision record's budget
(`docs/specs/dmd-fmt/`): the spine lex (the keystroke-path floor), the
parse-backed oracle, and the group builder, each over a synthetic ~2 kLOC
module, plus the full pipeline.

Run with `dub test :dmd-fmt -- --bench`.

Test-only module: benchmarks need the runner's `@benchmark` attribute, which
lives in the test-runner shim — a dependency only of the unittest
configuration.
*/
module sparkles.dmd_fmt.bench;

version (unittest):

import sparkles.test_runner.attributes : benchmark;

import sparkles.dmd_fmt.groups : buildGroups;
import sparkles.dmd_fmt.oracle : collectFacts;
import sparkles.dmd_fmt.spine : lexSpine;

// ~2000 lines of ordinary D: a 20-line unit (declaration with constraint,
// contracts, body, comments, a struct) repeated 100 times with unique names.
private string bigSource() @safe
{
    static string cached;
    if (cached.length)
        return cached;

    import std.array : appender;
    import std.format : formattedWrite;

    auto w = appender!string;
    w.put("module bench_fixture;\n\n");
    foreach (i; 0 .. 100)
        w.formattedWrite!(
            "/// Frobnicates the %1$s-th widget.\n" ~
            "auto frob%1$s(T, U)(T input, U seed) @safe pure\n" ~
            "if (isInputRange!T && is(U : long))\n" ~
            "in (seed > 0)\n" ~
            "out (r; r !is null)\n" ~
            "{\n" ~
            "    // local bookkeeping\n" ~
            "    auto acc = seed + %1$s;\n" ~
            "    if (acc > 1) { acc = frobImpl(input, acc); }\n" ~
            "    version (Tracing) { trace(\"frob%1$s\", acc); }\n" ~
            "    return wrap(acc);\n" ~
            "}\n" ~
            "\n" ~
            "struct Widget%1$s\n" ~
            "{\n" ~
            "    int x = %1$s;\n" ~
            "    invariant (x >= 0);\n" ~
            "    int scaled() const @safe pure nothrow => x * 2;\n" ~
            "}\n" ~
            "\n")(i);
    cached = w[];
    return cached;
}

@("bench.spine.lex-2kloc")
@benchmark @system unittest
{
    auto spine = lexSpine(bigSource);
    assert(spine.entries.length > 1000);
}

@("bench.oracle.parse-2kloc")
@benchmark @system unittest
{
    auto facts = collectFacts(bigSource);
    assert(facts.parsed);
}

@("bench.groups.full-pipeline-2kloc")
@benchmark @system unittest
{
    auto spine = lexSpine(bigSource);
    auto facts = collectFacts(bigSource);
    auto root = buildGroups(spine, facts);
    assert(root.children.length > 100);
}
