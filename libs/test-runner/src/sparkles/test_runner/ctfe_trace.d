/**
 * Attribution of compile-time (CTFE) cost to individual `@ctfe` tests from an
 * LDC `-ftime-trace` profile.
 *
 * The runner forces `@ctfe` tests through CTFE while the test build compiles,
 * so their cost shows up in the compiler's time trace as
 * `"Ctfe: call __unittest_LN_CM"` events whose `loc` field is the test's
 * source location. The `--ctfe-trace <trace.json>` runner mode matches those
 * events against the discovered `@ctfe` tests and reports a per-test table.
 *
 * To produce the trace, add LDC's flags to the package's unittest
 * configuration (see `libs/math/dub.sdl` for the established pattern):
 * ---
 * dflags "-ftime-trace" "-ftime-trace-file=$PACKAGE_DIR/build/trace.json" \
 *     "--ftime-trace-granularity=0" platform="ldc"
 * ---
 *
 * The trace can be 100+ MB, so instead of a full JSON parse this module does
 * a linear text scan for the handful of event shapes it cares about.
 */
module sparkles.test_runner.ctfe_trace;

import sparkles.test_runner.model : Test;

/// One `Ctfe: call __unittest_*` event from the trace.
struct CtfeTraceEvent
{
    string symbol; /// e.g. `__unittest_L148_C1`
    string loc; /// e.g. `libs/foo/src/foo/bar.d:148`
    long durUs; /// event duration in microseconds
}

/// Extracts every `"Ctfe: call __unittest_*"` event from a Chrome-trace JSON
/// text via a linear scan (field order as emitted by LDC: `name`, `ts`,
/// `dur`, `loc`).
CtfeTraceEvent[] parseCtfeEvents(string traceJson) @safe pure
{
    import std.string : indexOf;

    enum marker = `"Ctfe: call __unittest_`;

    CtfeTraceEvent[] events;
    for (size_t from = 0;;)
    {
        const at = traceJson.indexOf(marker, from);
        if (at < 0)
            break;

        const symbolStart = at + `"Ctfe: call `.length;
        // The scan window ends at the next `"name"` key (fields of one event
        // are adjacent; `args` may follow but contains no `dur`/`loc` keys).
        auto windowEnd = traceJson.indexOf(`"name"`, symbolStart);
        if (windowEnd < 0)
            windowEnd = traceJson.length;
        const window = traceJson[symbolStart .. windowEnd];

        CtfeTraceEvent event;
        event.symbol = window[0 .. window.indexOf('"')];
        event.durUs = numberField(window, `"dur"`);
        event.loc = stringField(window, `"loc"`);
        events ~= event;

        from = symbolStart;
    }
    return events;
}

/// The integer value of `"key": 123` inside `window`, or `-1`.
private long numberField(string window, string key) @safe pure
{
    import std.ascii : isDigit, isWhite;
    import std.string : indexOf;

    auto at = window.indexOf(key);
    if (at < 0)
        return -1;
    at += key.length;
    while (at < window.length && (window[at] == ':' || isWhite(window[at])))
        at++;

    long value = -1;
    for (; at < window.length && isDigit(window[at]); at++)
        value = (value < 0 ? 0 : value * 10) + (window[at] - '0');
    return value;
}

/// The value of `"key": "text"` inside `window`, or `null`.
private string stringField(string window, string key) @safe pure
{
    import std.string : indexOf;

    auto at = window.indexOf(key);
    if (at < 0)
        return null;
    at += key.length;
    const open = window.indexOf('"', at);
    if (open < 0)
        return null;
    const close = window.indexOf('"', open + 1);
    if (close < 0)
        return null;
    return window[open + 1 .. close];
}

@("parseCtfeEvents.basic")
@safe pure
unittest
{
    enum trace = `{"traceEvents":[` ~
        `{"ph":"X","name": "Ctfe: call foo","ts":1,"dur":5,"loc":"a.d:1","args":{}},` ~
        `{"ph":"X","name": "Ctfe: call __unittest_L148_C1","ts":317632,"dur":5818,` ~
        `"loc":"libs/test-runner/src/sparkles/test_runner/bench.d:148","args":{"detail":""}},` ~
        `{"ph":"X","name": "Ctfe: call __unittest_L9_C1","ts":9,"dur":42,"loc":"b.d:9","args":{}}]}`;

    enum events = parseCtfeEvents(trace);
    static assert(events == [
        CtfeTraceEvent(
            symbol: "__unittest_L148_C1",
            loc: "libs/test-runner/src/sparkles/test_runner/bench.d:148",
            durUs: 5818,
        ),
        CtfeTraceEvent(
            symbol: "__unittest_L9_C1",
            loc: "b.d:9",
            durUs: 42,
        )
    ]);
}

/// One `@ctfe` test with its attributed compile-time cost.
struct CtfeTestCost
{
    Test test;
    long durUs = -1; /// `-1` when the trace has no event for the test
}

/// Matches trace events to `@ctfe` tests by source location (`file:line`).
/// Multiple events for one test (re-evaluation) are summed.
CtfeTestCost[] attributeCtfeCosts(Test[] ctfeTests, CtfeTraceEvent[] events) @safe pure
{
    import std.conv : text;

    CtfeTestCost[] costs;
    foreach (test; ctfeTests)
    {
        auto cost = CtfeTestCost(test);
        const location = text(test.location.file, ':', test.location.line);
        foreach (event; events)
            if (event.loc == location && event.durUs >= 0)
                cost.durUs = (cost.durUs < 0 ? 0 : cost.durUs) + event.durUs;
        costs ~= cost;
    }
    return costs;
}

@("attributeCtfeCosts.matchAndMiss")
@safe pure
unittest
{
    import sparkles.test_runner.model : TestLocation;

    auto tests = [
        Test(fullName: "m.__unittest_L148_C1", name: "hit",
            location: TestLocation(file: "src/m.d", line: 148, column: 1)),
        Test(fullName: "m.__unittest_L7_C1", name: "miss",
            location: TestLocation(file: "src/m.d", line: 7, column: 1)),
    ];
    auto events = [
        CtfeTraceEvent(symbol: "__unittest_L148_C1", loc: "src/m.d:148", durUs: 100),
        CtfeTraceEvent(symbol: "__unittest_L148_C1", loc: "src/m.d:148", durUs: 20),
        CtfeTraceEvent(symbol: "__unittest_L9_C1", loc: "other.d:9", durUs: 5),
    ];

    const costs = attributeCtfeCosts(tests, events);
    assert(costs.length == 2);
    assert(costs[0].durUs == 120);
    assert(costs[1].durUs == -1);
}
